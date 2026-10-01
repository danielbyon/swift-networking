//
//  MockNetworkTransportTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Dispatch
import Foundation
import HTTPTypes
import Networking
import NetworkingTestSupport
import Testing

@Test("Mock transport consumes matching stubs in registration order")
func mockTransportConsumesMatchingStubsInRegistrationOrder() async throws {
    let url = try #require(URL(string: "https://mock.example/resource"))
    let firstStub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let fallbackStub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([2]), response: HTTPResponse(status: .init(code: 200))),
        consumption: .always,
    )
    let transport = MockNetworkTransport(stubs: [firstStub, fallbackStub])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDataRequest(url: url)

    let first = try await client.send(request)
    let second = try await client.send(request)

    #expect(first.value == Data([1]))
    #expect(second.value == Data([2]))
    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 2)
    #expect(recorded.map(\.attemptNumber) == [1, 1])
    try await transport.verifyAllFiniteStubsConsumed()
    try await transport.verifyRequestOrder([.method(.get), .method(.get)])
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Unmatched mock requests report sanitized details and never use live networking")
func unmatchedMockRequestsAreSanitizedAndFailInMockTransport() async throws {
    let url = try #require(URL(string: "https://mock.example/resource?token=query-secret"))
    let privateHeaderName = try #require(HTTPField.Name("X-API-Key"))
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.post),
            response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
        ),
    ])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDataRequest(url: url)
        .header(.authorization, "header-secret")
        .header(privateHeaderName, "custom-header-secret")

    do {
        _ = try await client.send(request)
        Issue.record("Expected an unmatched-request error from MockNetworkTransport")
    } catch let error as NetworkTestSupportError {
        let description = error.localizedDescription
        #expect(description.localizedCaseInsensitiveContains("unmatched"))
        #expect(description.contains("<redacted>"))
        #expect(!description.contains("query-secret"))
        #expect(!description.contains("header-secret"))
        #expect(!description.contains("custom-header-secret"))
        #expect(description.contains("stub[0]"))
        #expect(description.contains("method mismatch"))
        guard case let .unmatchedRequest(_, activeStubs) = error else {
            Issue.record("Expected the structured unmatched-request error")
            return
        }

        #expect(activeStubs.map(\.registrationIndex) == [0])
        #expect(activeStubs.first?.reasons == [.method])
    }

    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
}

@Test("Query matchers distinguish ordered exact matching from order-insensitive subsets")
func queryMatcherSemanticsAreExplicit() async throws {
    let url = try #require(URL(string: "https://mock.example/resource?a=1&b=2"))
    let subset = try NetworkStub(
        matching: .query(
            [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")],
            semantics: .subset,
        ),
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let reversedExact = try NetworkStub(
        matching: .query(
            [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")],
            semantics: .exact,
        ),
        response: .httpResponse(data: Data([2]), response: HTTPResponse(status: .init(code: 200))),
        consumption: .always,
    )
    let transport = MockNetworkTransport(stubs: [subset, reversedExact])
    let client = try NetworkClient.testing(transport: transport)

    let first = try await client.send(mockDataRequest(url: url))
    #expect(first.value == Data([1]))
    do {
        _ = try await client.send(mockDataRequest(url: url))
        Issue.record("Expected the reversed exact query matcher to reject the request")
    } catch let error as NetworkTestSupportError {
        #expect(error.localizedDescription.contains("query mismatch"))
    }
}

@Test("Header subset and exact matching ignore field iteration order")
func headerMatcherSemanticsAreExplicitAndOrderInsensitive() async throws {
    let url = try #require(URL(string: "https://mock.example/resource"))
    var acceptOnly = HTTPFields()
    acceptOnly[fields: .accept] = [HTTPField(name: .accept, value: "application/json")]
    var exactHeaders = HTTPFields()
    exactHeaders[fields: .accept] = [HTTPField(name: .accept, value: "application/json")]
    exactHeaders[fields: .authorization] = [HTTPField(name: .authorization, value: "token")]
    let subset = try NetworkStub(
        matching: .headers(acceptOnly, semantics: .subset),
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let exact = try NetworkStub(
        matching: .headers(exactHeaders, semantics: .exact),
        response: .httpResponse(data: Data([2]), response: HTTPResponse(status: .init(code: 200))),
        consumption: .always,
    )
    let transport = MockNetworkTransport(stubs: [subset, exact])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDataRequest(url: url)
        .header(.authorization, "token")
        .header(.accept, "application/json")

    let first = try await client.send(request)
    let second = try await client.send(request)

    #expect(first.value == Data([1]))
    #expect(second.value == Data([2]))
}

@Test("Request matchers compose method, path, context, attempt, negation, and custom predicates")
func requestMatchersComposeWithoutExposingProductionInjection() async throws {
    let url = try #require(URL(string: "https://mock.example/resource?tag=one&tag=two"))
    let matcher = RequestMatcher.method(.post)
        .or(.method(.get))
        .and(.url(url))
        .and(.path("/resource"))
        .and(.query(
            [URLQueryItem(name: "tag", value: "one"), URLQueryItem(name: "tag", value: "two")],
            semantics: .exact,
        ))
        .and(.requestContext(MockTraceKey.self, equals: "trace-7"))
        .and(.attemptNumber(1))
        .and(.method(.delete).not())
        .and(.custom { $0.httpRequest.authority == "mock.example" })
    let stub = try NetworkStub(
        matching: matcher,
        response: .httpResponse(data: Data([7]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDataRequest(url: url).context(MockTraceKey.self, value: "trace-7")

    let response = try await client.send(request)

    #expect(response.value == Data([7]))
    let recording = try #require(await transport.recordedRequests().first)
    #expect(recording.requestContext[MockTraceKey.self] == "trace-7")
}

@Test("Request-context matchers accept key types that are not Sendable")
func requestContextMatcherAcceptsNonSendableKeyTypes() async throws {
    let url = try #require(URL(string: "https://mock.example/non-sendable-context"))
    let stub = try NetworkStub(
        matching: .requestContext(NonSendableContextKey.self, equals: "trace-8"),
        response: .httpResponse(data: Data([8]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDataRequest(url: url).context(NonSendableContextKey.self, value: "trace-8")

    let response = try await client.send(request)

    #expect(response.value == Data([8]))
}

@Test("Request matchers and recordings observe ordinary adapter mutations")
func requestMatcherAndRecordingObserveConfiguredAdapterMutation() async throws {
    let url = try #require(URL(string: "https://mock.example/adapted"))
    let headerName = try #require(HTTPField.Name("X-Adapter-Mutation"))
    let headerValue = "adapted-value"
    let adapter = AnyRequestAdapter(adapt: { context in
        var request = context.request
        request.headerFields[fields: headerName] = [HTTPField(name: headerName, value: headerValue)]
        return request
    })
    let configuration = NetworkClient.Configuration().withRequestAdapter(adapter)
    var expectedHeaders = HTTPFields()
    expectedHeaders[fields: headerName] = [HTTPField(name: headerName, value: headerValue)]
    let stub = try NetworkStub(
        matching: .headers(expectedHeaders, semantics: .subset),
        response: .httpResponse(data: Data([9]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let response = try await client.send(mockDataRequest(url: url))

    #expect(response.value == Data([9]))
    let recording = try #require(await transport.recordedRequests().first)
    #expect(recording.httpRequest.headerFields[fields: headerName].first?.value == headerValue)
}

@Test("Semantic JSON matching ignores object order but preserves arrays and exact numbers")
func semanticJSONMatchingUsesDecodedJSONSemantics() async throws {
    let url = try #require(URL(string: "https://mock.example/json"))
    let expected = Data(
        #"""
        {
            "count": 1.0,
            "integer": 1,
            "exponent": 1e0,
            "extreme": 1e-9999999999999999999999999999999999999999,
            "zero": 0,
            "items": [2, 3],
            "name": "example"
        }
        """#.utf8,
    )
    let actual = Data(
        #"""
        {
            "name": "example",
            "items": [2, 3],
            "zero": -0.0,
            "extreme": 10e-10000000000000000000000000000000000000000,
            "exponent": 1.0,
            "integer": 1e0,
            "count": 1
        }
        """#.utf8,
    )
    let matcher = try RequestMatcher.jsonBody(expected)
    let stub = try NetworkStub(
        matching: matcher,
        response: .httpResponse(data: Data([9]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockJSONRequest(url: url, body: actual)

    let response = try await client.send(request)

    #expect(response.value == Data([9]))
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Semantic JSON matching rejects array reordering and numeric tolerance")
func semanticJSONMatchingRejectsArrayReorderingAndNearNumbers() async throws {
    let url = try #require(URL(string: "https://mock.example/json"))
    let expected = Data(#"{"values":[1,2],"count":1}"#.utf8)
    let actual = Data(#"{"count":1.0000000001,"values":[2,1]}"#.utf8)
    let stub = try NetworkStub(
        matching: .jsonBody(expected),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)

    do {
        _ = try await client.send(mockJSONRequest(url: url, body: actual))
        Issue.record("Expected semantic JSON matching to reject changed array order and number")
    } catch let error as NetworkTestSupportError {
        #expect(error.localizedDescription.contains("semantic JSON body mismatch"))
        #expect(!error.localizedDescription.contains("1.0000000001"))
    }
}

@Test("Semantic JSON matching preserves arbitrary precision and extreme exponents")
func semanticJSONMatchingPreservesLosslessNumbers() async throws {
    let numberPairs = [
        (
            #"{"number":123456789012345678901234567890123456789012345}"#,
            #"{"number":123456789012345678901234567890123456789012346}"#,
        ),
        (
            #"{"number":12345678901234567890.1234567890123456789012345}"#,
            #"{"number":12345678901234567890.1234567890123456789012346}"#,
        ),
        (#"{"number":1e-400}"#, #"{"number":2e-400}"#),
    ]

    for (expected, actual) in numberPairs {
        let url = try #require(URL(string: "https://mock.example/lossless-json"))
        let stub = try NetworkStub(
            matching: .jsonBody(Data(expected.utf8)),
            response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
        )
        let transport = MockNetworkTransport(stubs: [stub])
        let client = try NetworkClient.testing(transport: transport)

        do {
            _ = try await client.send(mockJSONRequest(url: url, body: Data(actual.utf8)))
            Issue.record("Expected mathematically distinct JSON numbers not to match")
        } catch let error as NetworkTestSupportError {
            #expect(error.localizedDescription.contains("semantic JSON body mismatch"))
        }
    }
}

@Test("Semantic JSON matching rejects adjacent numeric tokens without a separator")
func semanticJSONMatchingRejectsAdjacentNumericTokens() async throws {
    let url = try #require(URL(string: "https://mock.example/malformed-number"))
    let expected = Data(#"[0,0,0,0,0,0,0,0,0,0,0,0]"#.utf8)
    let malformedActual = Data(#"[0,1-2,0,0,0,0,0,0,0,0,0,0]"#.utf8)
    let stub = try NetworkStub(
        matching: .jsonBody(expected),
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)

    do {
        _ = try await client.send(mockJSONRequest(url: url, body: malformedActual))
        Issue.record("Expected malformed JSON numeric tokens not to match")
    } catch let error as NetworkTestSupportError {
        #expect(error.localizedDescription.contains("semantic JSON body mismatch"))
    }
}

@Test("Semantic JSON matcher construction rejects malformed expected JSON")
func semanticJSONMatcherRejectsMalformedExpectedJSON() {
    #expect(throws: RequestMatcherError.invalidJSON) {
        try RequestMatcher.jsonBody(Data("{bad json}".utf8))
    }
    #expect(throws: RequestMatcherError.invalidJSON) {
        try RequestMatcher.jsonBody(Data("tru1".utf8))
    }
}

@Test("Built-in and custom matchers report structured mismatch reasons")
func matcherFailuresHaveStructuredReasons() async throws {
    let url = try #require(URL(string: "https://mock.example/matchers?actual=value"))
    let otherURL = try #require(URL(string: "https://other.example/different"))
    let wrongContext = RequestMatcher.requestContext(MockTraceKey.self, equals: "expected")
    let mismatches: [(RequestMatcher, RequestMismatchReason)] = try [
        (.method(.post), .method),
        (.method(.post).and(.path("/wrong")), .allOf([.method, .path])),
        (.method(.post).or(.method(.delete)), .anyOf([.method, .method])),
        (.method(.get).not(), .negatedMatcherMatched),
        (.url(otherURL), .url),
        (.path("/different"), .path),
        (.query([URLQueryItem(name: "missing", value: "value")], semantics: .exact), .query),
        (.headers(authorizationFields("wrong"), semantics: .exact), .headers),
        (.body(Data([1])), .body),
        (.jsonBody(Data("[]".utf8)), .semanticJSONBody),
        (wrongContext, .requestContext),
        (.attemptNumber(2), .attemptNumber),
        (.custom { _ in false }, .customMatcher),
    ]
    let request = mockDataRequest(url: url).context(MockTraceKey.self, value: "trace-7")

    for (matcher, expectedReason) in mismatches {
        let stub = try NetworkStub(
            matching: matcher,
            response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
        )
        let transport = MockNetworkTransport(stubs: [stub])
        let client = try NetworkClient.testing(transport: transport)
        do {
            _ = try await client.send(request)
            Issue.record("Expected matcher failure for \(expectedReason)")
        } catch let error as NetworkTestSupportError {
            guard case let .unmatchedRequest(_, activeStubs) = error else {
                Issue.record("Expected a structured unmatched-request error")
                continue
            }

            #expect(activeStubs.count == 1)
            #expect(activeStubs.first?.reasons == [expectedReason])
        }
    }
}

@Test("And mismatch diagnostics list only child matchers that failed")
func andMismatchDiagnosticsListOnlyFailedChildren() async throws {
    let url = try #require(URL(string: "https://mock.example/and-mismatch"))
    let stub = try NetworkStub(
        matching: .method(.get).and(.path("/different")),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)

    do {
        _ = try await client.send(mockDataRequest(url: url))
        Issue.record("Expected the path child matcher to reject the request")
    } catch let error as NetworkTestSupportError {
        guard case let .unmatchedRequest(_, activeStubs) = error else {
            Issue.record("Expected an unmatched-request diagnostic")
            return
        }

        #expect(activeStubs.first?.reasons == [.allOf([.path])])
        #expect(error.localizedDescription.contains("and composition failed (child mismatches: path mismatch)"))
        #expect(!error.localizedDescription.contains("method mismatch"))
    }
}

@Test("Finite stub counts must be positive")
func finiteStubConsumptionRejectsZeroAndNegativeCounts() {
    let response = StubResponse.httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200)))
    for count in [0, -1] {
        #expect(throws: NetworkStub.ConfigurationError.finiteConsumptionMustBePositive) {
            try NetworkStub(matching: .method(.get), response: response, consumption: .finite(count))
        }
    }
}

@Test("Authentication replay records each final adapted request and groups attempts by request ID")
func authenticationReplayRecordsTransportReadyAttempts() async throws {
    let url = try #require(URL(string: "https://mock.example/authenticated"))
    let firstHeaders = authorizationFields("token-1")
    let secondHeaders = authorizationFields("token-2")
    let firstStub = try NetworkStub(
        matching: .headers(firstHeaders, semantics: .subset).and(.attemptNumber(1)),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 401))),
    )
    let secondStub = try NetworkStub(
        matching: .headers(secondHeaders, semantics: .subset).and(.attemptNumber(2)),
        response: .httpResponse(data: Data([2]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [firstStub, secondStub])
    let provider = ReplayingAuthenticationProvider(counter: AuthTokenCounter())
    let configuration = NetworkClient.Configuration().withAuthenticationProvider(provider)
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    .authenticationRequirement(.required(maximumReplays: 1))

    let response = try await client.send(Request(endpoint: endpoint))

    #expect(response.value == Data([2]))
    let recorded = await transport.recordedRequests()
    #expect(recorded.map(\.attemptNumber) == [1, 2])
    #expect(recorded.map { $0.httpRequest.headerFields[.authorization] } == ["token-1", "token-2"])
    let groups = await transport.recordedRequestsByRequestID()
    #expect(groups.count == 1)
    #expect(groups.first?.attempts.map(\.attemptNumber) == [1, 2])
    #expect(groups.first?.requestID == recorded.first?.requestID)
    try await transport.verifyRequestOrder([
        .headers(firstHeaders, semantics: .subset).and(.attemptNumber(1)),
        .headers(secondHeaders, semantics: .subset).and(.attemptNumber(2)),
    ])
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Finite stubs consume the configured number of actual retry attempts")
func finiteStubConsumptionTracksTransportAttempts() async throws {
    let url = try #require(URL(string: "https://mock.example/retry"))
    let first = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 503))),
        consumption: .finite(2),
    )
    let last = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [first, last])
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 2
    let configuration = NetworkClient.Configuration()
        .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let response = try await client.send(mockDataRequest(url: url))

    #expect(response.value == Data([1]))
    #expect(await transport.recordedRequests().map(\.attemptNumber) == [1, 2, 3])
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Mock download flows through accepted response finalization and caller ownership")
func mockDownloadUsesLibraryOwnedFileLifecycle() async throws {
    let url = try #require(URL(string: "https://mock.example/download"))
    let destination = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("swift-networking-mock-result-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }
    let payload = Data([0, 1, 2, 255])
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .download(data: payload, response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let request = mockDownloadRequest(url: url).downloadDestination(.file(destination))

    let response = try await client.send(request)

    #expect(response.value.url == destination)
    #expect(try Data(contentsOf: destination) == payload)
    try response.value.remove()
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test("File-backed upload matching and inspection read bytes only through explicit APIs")
func fileBackedRequestBodyCanBeMatchedAndInspectedExplicitly() async throws {
    let url = try #require(URL(string: "https://mock.example/upload"))
    let fileURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("swift-networking-mock-body-\(UUID().uuidString)")
    let payload = Data([8, 0, 9, 255])
    try payload.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let stub = try NetworkStub(
        matching: .body(payload),
        response: .httpResponse(data: Data([3]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let endpoint = Endpoint<Never, URL, Data>.data(
        method: .put,
        route: .absolute(url),
        body: .file(contentType: "application/octet-stream"),
        response: .data,
    )

    let response = try await client.send(Request(endpoint: endpoint, body: fileURL))

    #expect(response.value == Data([3]))
    let recorded = try #require(await transport.recordedRequests().first)
    guard case let .file(recordedURL) = recorded.preparedBody else {
        Issue.record("Expected the request body recording to retain file metadata")
        return
    }

    #expect(recordedURL == fileURL)
    #expect(recorded.preparedBodyFileSize == UInt64(payload.count))
    let updatedPayload = Data([8, 0, 9, 254])
    try updatedPayload.write(to: fileURL)
    #expect(try recorded.readBodyBytes() == updatedPayload)
}

@Test("Mock transport propagates arbitrary stub failures unchanged")
func mockTransportPropagatesArbitraryStubFailure() async throws {
    let url = try #require(URL(string: "https://mock.example/failure"))
    let stub = try NetworkStub(matching: .method(.get), response: .failure(MockFailure.rejected))
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)

    do {
        _ = try await client.send(mockDataRequest(url: url))
        Issue.record("Expected the configured transport failure")
    } catch let error as MockFailure {
        #expect(error == .rejected)
    }
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Stub response kinds incompatible with an operation fail inside the mock")
func mockTransportRejectsIncompatibleResponseKinds() async throws {
    let url = try #require(URL(string: "https://mock.example/operation"))
    func assertMismatch(request: Request<some Sendable>, response: StubResponse) async throws {
        let stub = try NetworkStub(matching: .method(.get), response: response)
        let transport = MockNetworkTransport(stubs: [stub])
        let client = try NetworkClient.testing(transport: transport)
        do {
            _ = try await client.send(request)
            Issue.record("Expected the response kind to be rejected for the selected operation")
        } catch let error as NetworkTestSupportError {
            guard case .responseOperationMismatch = error else {
                Issue.record("Unexpected mock response-operation error")
                return
            }
        }
        #expect(await transport.recordedRequests().count == 1)
        try await transport.verifyAllFiniteStubsConsumed()
    }

    try await assertMismatch(
        request: mockDataRequest(url: url),
        response: .download(data: Data(), response: HTTPResponse(status: .init(code: 200))),
    )
    try await assertMismatch(
        request: mockDownloadRequest(url: url),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
    )
}

@Test("Explicit cancellation verification observes cancellation after transport start")
func mockTransportRecordsCancellationAfterAttemptStart() async throws {
    let url = try #require(URL(string: "https://mock.example/cancel"))
    let enteredMatcher = DispatchSemaphore(value: 0)
    let releaseMatcher = DispatchSemaphore(value: 0)
    let stub = try NetworkStub(
        matching: .custom { _ in
            enteredMatcher.signal()
            releaseMatcher.wait()
            return true
        },
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let networkTask = client.task(for: mockDataRequest(url: url))
    let waiter = Task { try await networkTask.value }

    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            enteredMatcher.wait()
            continuation.resume()
        }
    }
    networkTask.cancel()
    releaseMatcher.signal()
    do {
        _ = try await waiter.value
        Issue.record("Expected cancellation to reach the mock transport")
    } catch is CancellationError {}

    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
    #expect(recorded.first?.cancellationObserved == true)
    try await transport.verifyCancellationObserved()
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Cancellation preserves file metadata captured before the matcher runs")
func mockTransportCancellationPreservesCapturedFileMetadata() async throws {
    let url = try #require(URL(string: "https://mock.example/cancel-file"))
    let fileURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("swift-networking-cancel-body-\(UUID().uuidString)")
    let payload = Data([1, 2, 3, 4, 5])
    try payload.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let enteredMatcher = DispatchSemaphore(value: 0)
    let releaseMatcher = DispatchSemaphore(value: 0)
    let stub = try NetworkStub(
        matching: .custom { _ in
            enteredMatcher.signal()
            releaseMatcher.wait()
            return true
        },
        response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let endpoint = Endpoint<Never, URL, Data>.data(
        method: .put,
        route: .absolute(url),
        body: .file(contentType: "application/octet-stream"),
        response: .data,
    )
    let networkTask = client.task(for: Request(endpoint: endpoint, body: fileURL))
    let waiter = Task { try await networkTask.value }

    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            enteredMatcher.wait()
            continuation.resume()
        }
    }
    try FileManager.default.removeItem(at: fileURL)
    networkTask.cancel()
    releaseMatcher.signal()

    do {
        _ = try await waiter.value
        Issue.record("Expected cancellation to reach the mock transport")
    } catch is CancellationError {}

    let recorded = try #require(await transport.recordedRequests().first)
    #expect(recorded.cancellationObserved)
    #expect(recorded.preparedBodyFileSize == UInt64(payload.count))
    try await transport.verifyCancellationObserved()
}

@Test("Full URL matching rejects absent components while path and query remain usable")
func fullURLMatcherRejectsMissingSchemeAndAuthority() async throws {
    let url = try #require(URL(string: "https://matcher.invalid/malformed?state=one"))

    for removesScheme in [true, false] {
        let adapter = AnyRequestAdapter(adapt: { context in
            var request = context.request
            if removesScheme {
                request.scheme = nil
            } else {
                request.authority = nil
            }
            return request
        })
        let configuration = NetworkClient.Configuration().withRequestAdapter(adapter)
        let urlStub = try NetworkStub(
            matching: .url(url),
            response: .httpResponse(data: Data([1]), response: HTTPResponse(status: .init(code: 200))),
        )
        let urlTransport = MockNetworkTransport(stubs: [urlStub])
        let urlClient = try NetworkClient.testing(configuration: configuration, transport: urlTransport)

        do {
            _ = try await urlClient.send(mockDataRequest(url: url))
            Issue.record("Expected a full URL matcher to reject an absent URL component")
        } catch let error as NetworkTestSupportError {
            guard case let .unmatchedRequest(_, activeStubs) = error else {
                Issue.record("Expected a full URL mismatch diagnostic")
                continue
            }

            #expect(activeStubs.first?.reasons == [.url])
        }

        let recordedURLRequest = try #require(await urlTransport.recordedRequests().first)
        if removesScheme {
            #expect(recordedURLRequest.httpRequest.scheme == nil)
        } else {
            #expect(recordedURLRequest.httpRequest.authority == nil)
        }

        let pathAndQueryStub = try NetworkStub(
            matching: .path("/malformed").and(.query(
                [URLQueryItem(name: "state", value: "one")],
                semantics: .exact,
            )),
            response: .httpResponse(data: Data([2]), response: HTTPResponse(status: .init(code: 200))),
        )
        let pathAndQueryTransport = MockNetworkTransport(stubs: [pathAndQueryStub])
        let pathAndQueryClient = try NetworkClient.testing(
            configuration: configuration,
            transport: pathAndQueryTransport,
        )

        let response = try await pathAndQueryClient.send(mockDataRequest(url: url))
        #expect(response.value == Data([2]))
    }
}

@Test("Explicit verification reports unused stubs and order mismatches without changing recordings")
func explicitVerificationReportsFailuresWithoutConsumingStubs() async throws {
    let url = try #require(URL(string: "https://mock.example/verify"))
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data(), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport()
    await transport.register(stub)

    do {
        try await transport.verifyCancellationObserved()
        Issue.record("Expected cancellation verification to report no observed cancellation")
    } catch let error as NetworkTestSupportError {
        guard case .cancellationNotObserved = error else {
            Issue.record("Unexpected cancellation verification error")
            return
        }
    }

    do {
        try await transport.verifyRequestOrder([.method(.get)])
        Issue.record("Expected an empty recording to fail request-order count verification")
    } catch let error as NetworkTestSupportError {
        guard case .requestCountMismatch(expected: 1, actual: 0) = error else {
            Issue.record("Unexpected request-count verification error")
            return
        }
    }

    do {
        try await transport.verifyAllFiniteStubsConsumed()
        Issue.record("Expected verification to report an unused finite stub")
    } catch let error as NetworkTestSupportError {
        guard case .finiteStubsNotConsumed([0]) = error else {
            Issue.record("Unexpected finite-stub verification error")
            return
        }
    }
    let client = try NetworkClient.testing(transport: transport)
    _ = try await client.send(mockDataRequest(url: url))
    do {
        try await transport.verifyRequestOrder([.method(.post)])
        Issue.record("Expected request-order verification to fail")
    } catch let error as NetworkTestSupportError {
        guard case .requestOrderMismatch(index: 0, reason: .method) = error else {
            Issue.record("Unexpected request-order verification error")
            return
        }
    }
    #expect(await transport.recordedRequests().count == 1)
    try await transport.verifyAllFiniteStubsConsumed()
}

private func mockDataRequest(url: URL) -> Request<Data> {
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func mockJSONRequest(url: URL, body: Data) -> Request<Data> {
    let endpoint = Endpoint<Never, Data, Data>.data(
        method: .post,
        route: .absolute(url),
        body: .data(),
        response: .data,
    )
    return Request(endpoint: endpoint, body: body)
}

private func mockDownloadRequest(url: URL) -> Request<DownloadedFile> {
    let endpoint = Endpoint<Never, Never, DownloadedFile>.download(method: .get, route: .absolute(url))
    return Request(endpoint: endpoint)
}

private enum MockTraceKey: RequestContextKey, Sendable {
    typealias Value = String
}

private final class NonSendableContextKey: RequestContextKey {
    typealias Value = String
}

private func authorizationFields(_ value: String) -> HTTPFields {
    var fields = HTTPFields()
    fields[fields: .authorization] = [HTTPField(name: .authorization, value: value)]
    return fields
}

private actor AuthTokenCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private struct ReplayingAuthenticationProvider: AuthenticationProvider {
    let counter: AuthTokenCounter

    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        var request = context.request
        let token = await counter.next()
        request.headerFields[fields: .authorization] = [
            HTTPField(name: .authorization, value: "token-\(token)"),
        ]
        return request
    }

    func recover(_ context: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        context.attemptNumber == 1 ? .replay : .doNotReplay
    }
}

private enum MockFailure: Error, Sendable, Equatable {
    case rejected
}
