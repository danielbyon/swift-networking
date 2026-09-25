//
//  RedirectPolicyTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct RedirectPolicyTests {
    @Test("The default redirect policy follows with a ten redirect limit")
    func defaultPolicyFollowsWithTenRedirectLimit() throws {
        let context = try makeContext(
            currentURL: "https://example.com/start",
            proposedURL: "https://example.com/next",
        )

        #expect(RedirectPolicy.follow.maximumRedirects == 10)
        #expect(RedirectPolicy.follow.decision(for: context) == .follow)
        #expect(RedirectPolicy.follow(maximumRedirects: 2).maximumRedirects == 2)
    }

    @Test("The reject policy rejects without consuming its configured redirect budget")
    func rejectPolicyDoesNotFollow() throws {
        let context = try makeContext(
            currentURL: "https://example.com/start",
            proposedURL: "https://example.com/next",
        )
        let policy = RedirectPolicy.reject(maximumRedirects: 0)

        #expect(policy.maximumRedirects == 0)
        #expect(policy.decision(for: context) == .reject)
    }

    @Test("Same-origin policy normalizes scheme and default ports")
    func sameOriginPolicyNormalizesSchemeAndDefaultPorts() throws {
        let cases = [
            ("http://example.com/start", "HTTP://EXAMPLE.COM:80/next"),
            ("https://example.com/start", "HTTPS://EXAMPLE.COM:443/next"),
        ]

        for (currentURL, proposedURL) in cases {
            let context = try makeContext(currentURL: currentURL, proposedURL: proposedURL)
            #expect(RedirectPolicy.sameOriginOnly.decision(for: context) == .follow)
        }
    }

    @Test("Same-origin policy rejects a changed scheme host or effective port")
    func sameOriginPolicyRejectsDifferentOrigins() throws {
        let cases = [
            ("https://example.com/start", "http://example.com/next"),
            ("https://example.com/start", "https://other.example/next"),
            ("https://example.com/start", "https://example.com:444/next"),
        ]

        for (currentURL, proposedURL) in cases {
            let context = try makeContext(currentURL: currentURL, proposedURL: proposedURL)
            #expect(RedirectPolicy.sameOriginOnly.decision(for: context) == .reject)
        }
    }

    @Test("Same-origin policy rejects requests without a supported effective origin")
    func sameOriginPolicyRejectsMissingOrUnsupportedOrigin() throws {
        let cases = [
            ("https://example.com/start", "/next"),
            ("custom://example.com/start", "custom://example.com/next"),
        ]

        for (currentURL, proposedURL) in cases {
            let context = try makeContext(currentURL: currentURL, proposedURL: proposedURL)
            #expect(RedirectPolicy.sameOriginOnly.decision(for: context) == .reject)
        }
    }

    @Test("Custom policy receives the complete redirect and execution context")
    func customPolicyReceivesCompleteContext() throws {
        let requestID = RequestID(rawValue: UUID())
        let requestContext = RequestContext().setting(RedirectTraceKey.self, value: "trace-42")
        let context = try makeContext(
            currentURL: "https://example.com/start",
            proposedURL: "https://example.com/next",
            currentMethod: "POST",
            proposedMethod: "GET",
            requestID: requestID,
            requestContext: requestContext,
            attemptNumber: 4,
            redirectOrdinal: 2,
        )
        let policy = RedirectPolicy.custom(maximumRedirects: 5) { context in
            guard context.currentRequest.url?.absoluteString == "https://example.com/start",
                  context.currentRequest.httpMethod == "POST",
                  context.proposedRequest.url?.absoluteString == "https://example.com/next",
                  context.proposedRequest.httpMethod == "GET",
                  context.httpResponse.status.code == 302,
                  context.requestID == requestID,
                  context.requestContext[RedirectTraceKey.self] == "trace-42",
                  context.attemptNumber == 4,
                  context.redirectOrdinal == 2
            else {
                return .reject
            }

            return .follow
        }

        #expect(policy.maximumRedirects == 5)
        #expect(policy.decision(for: context) == .follow)
    }

    @Test("Client, endpoint, and request redirect policies use immutable replacement")
    func policyPrecedenceAndCopiesPreserveRedirectPolicy() throws {
        let url = try #require(URL(string: "https://example.com/redirect"))
        let clientPolicy = RedirectPolicy.reject(maximumRedirects: 1)
        let endpointPolicy = RedirectPolicy.follow(maximumRedirects: 2)
        let requestPolicy = RedirectPolicy.sameOriginOnly(maximumRedirects: 3)
        let validationPolicy = ResponseValidationPolicy.custom { _ in .accept }
        let baseEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        let endpoint = baseEndpoint.redirectPolicy(endpointPolicy)

        #expect(NetworkClient.Configuration().redirectPolicy.maximumRedirects == 10)
        let configuration = NetworkClient.Configuration()
            .withRedirectPolicy(clientPolicy)
            .withDefaultHeaders(HTTPFields())
            .withRequestTimeout(.seconds(5))
        #expect(configuration.redirectPolicy.maximumRedirects == 1)

        let endpointCopies: [Endpoint<Never, Never, Data>] = [
            endpoint.headers(HTTPFields()),
            endpoint.headers { _ in HTTPFields() },
            endpoint.header(.accept, "endpoint"),
            endpoint.jsonEncoderConfiguration { $0.outputFormatting = .sortedKeys },
            endpoint.jsonDecoderConfiguration { $0.keyDecodingStrategy = .convertFromSnakeCase },
            endpoint.validationPolicy(validationPolicy),
            endpoint.successfulResponseBodyRetentionPolicy(.none),
            endpoint.validationErrorBodyRetentionPolicy(.unlimited),
            endpoint.authenticationRequirement(.required(maximumReplays: 0)),
            endpoint.retryPolicy(RetryPolicy()),
            endpoint.retryPolicy { $0.maximumRetries = 1 },
        ]
        for copy in endpointCopies {
            #expect(copy.redirectPolicy?.maximumRedirects == 2)
        }

        let inputEndpoint = Endpoint<Int, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: 0) { _ in url },
            response: .data,
        )
        .headers { _ in HTTPFields() }
        .redirectPolicy(endpointPolicy)
        #expect(inputEndpoint.header(.accept, "input").redirectPolicy?.maximumRedirects == 2)

        let bodyEncoding = BodyEncoding<String>.custom { Data($0.utf8) }
        let bodyfulEndpoint = Endpoint<Never, String, Data>.data(
            method: .post,
            route: .absolute(url),
            body: bodyEncoding,
            response: .data,
        )
        .redirectPolicy(endpointPolicy)
        let inputBodyfulEndpoint = Endpoint<Int, String, Data>.data(
            method: .post,
            route: .absolute(forInput: 0) { _ in url },
            body: bodyEncoding,
            response: .data,
        )
        .redirectPolicy(endpointPolicy)

        let capturedRequests = [
            Request(endpoint: endpoint),
            Request(endpoint: inputEndpoint, input: 42),
            Request(endpoint: bodyfulEndpoint, body: "payload"),
            Request(endpoint: inputBodyfulEndpoint, input: 42, body: "payload"),
        ]
        for request in capturedRequests {
            #expect(request.redirectPolicy?.maximumRedirects == 2)
        }

        let request = Request(endpoint: endpoint).redirectPolicy(requestPolicy)
        let requestCopies: [Request<Data>] = [
            request.context(RedirectTraceKey.self, value: "trace-1"),
            request.queryItems([URLQueryItem(name: "page", value: "2")]),
            request.headers(HTTPFields()),
            request.header(.accept, "request"),
            request.validationPolicy(validationPolicy),
            request.successfulResponseBodyRetentionPolicy(.none),
            request.validationErrorBodyRetentionPolicy(.unlimited),
            request.retryPolicy(RetryPolicy()),
            request.retryPolicy { $0.maximumRetries = 1 },
        ]
        for copy in requestCopies {
            #expect(copy.redirectPolicy?.maximumRedirects == 3)
        }

        #expect(Request(endpoint: endpoint).redirectPolicy(requestPolicy).redirectPolicy?.maximumRedirects == 3)
    }

    @Test("The URLSession delegate forwards Foundation's proposed request and supplies redirect context")
    func delegateForwardsProposedRequestAndSuppliesRedirectContext() throws {
        let initialURL = try #require(URL(string: "https://example.com/start"))
        let initialRequest = URLRequest(url: initialURL)
        let requestID = RequestID(rawValue: UUID())
        let requestContext = RequestContext().setting(RedirectTraceKey.self, value: "trace-delegate")
        let receivedContexts = Mutex<[RedirectPolicy.Context]>([])
        let policy = RedirectPolicy.custom(maximumRedirects: 2) { context in
            receivedContexts.withLock { $0.append(context) }
            return .follow
        }
        let transportRequest = makeTransportRequest(
            initialURL: initialURL,
            policy: policy,
            requestID: requestID,
            requestContext: requestContext,
            attemptNumber: 4,
        )
        let delegate = URLSessionTaskMetricsDelegate(transportRequest: transportRequest, initialRequest: initialRequest)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initialRequest)
        var firstProposal = try URLRequest(url: #require(URL(string: "https://example.com/next")))
        firstProposal.httpMethod = "PATCH"
        firstProposal.setValue("preserved", forHTTPHeaderField: "X-Proposed")
        firstProposal.httpBody = Data("foundation-body".utf8)
        var secondProposal = try URLRequest(url: #require(URL(string: "https://example.com/final")))
        secondProposal.httpMethod = "GET"
        let response = try makeRedirectResponse(for: initialURL)

        let firstForwarded = invokeRedirect(
            delegate: delegate,
            session: session,
            task: task,
            response: response,
            proposedRequest: firstProposal,
        )
        let secondForwarded = invokeRedirect(
            delegate: delegate,
            session: session,
            task: task,
            response: response,
            proposedRequest: secondProposal,
        )
        let contexts = receivedContexts.withLock { $0 }

        #expect(firstForwarded?.url == firstProposal.url)
        #expect(firstForwarded?.httpMethod == firstProposal.httpMethod)
        #expect(firstForwarded?.value(forHTTPHeaderField: "X-Proposed") == "preserved")
        #expect(firstForwarded?.httpBody == Data("foundation-body".utf8))
        #expect(secondForwarded?.url == secondProposal.url)
        #expect(contexts.count == 2)
        #expect(contexts[0].currentRequest.url == initialURL)
        #expect(contexts[0].proposedRequest.url == firstProposal.url)
        #expect(contexts[0].httpResponse.status.code == 302)
        #expect(contexts[0].requestID == requestID)
        #expect(contexts[0].requestContext[RedirectTraceKey.self] == "trace-delegate")
        #expect(contexts[0].attemptNumber == 4)
        #expect(contexts[0].redirectOrdinal == 1)
        #expect(contexts[1].redirectOrdinal == 2)
    }

    @Test("Redirect limits apply only to follow decisions and count per transport attempt")
    func redirectLimitAppliesOnlyToFollowAndResetsPerAttempt() throws {
        let initialURL = try #require(URL(string: "https://example.com/start"))
        let initialRequest = URLRequest(url: initialURL)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initialRequest)
        let response = try makeRedirectResponse(for: initialURL)
        let proposedRequest = try URLRequest(url: #require(URL(string: "https://example.com/next")))
        let redirectContexts = Mutex<[(attemptNumber: UInt, redirectOrdinal: UInt)]>([])
        let limitedPolicy = RedirectPolicy.custom(maximumRedirects: 1) { context in
            redirectContexts.withLock {
                $0.append((context.attemptNumber, context.redirectOrdinal))
            }
            return .follow
        }

        let rejectingRequest = makeTransportRequest(
            initialURL: initialURL,
            policy: .reject(maximumRedirects: 0),
        )
        let rejectingDelegate = URLSessionTaskMetricsDelegate(
            transportRequest: rejectingRequest,
            initialRequest: initialRequest,
        )
        #expect(
            invokeRedirect(
                delegate: rejectingDelegate,
                session: session,
                task: task,
                response: response,
                proposedRequest: proposedRequest,
            ) == nil,
        )
        #expect(rejectingDelegate.redirectLimitExceeded()?.maximumRedirects == nil)

        let limitedRequest = makeTransportRequest(
            initialURL: initialURL,
            policy: limitedPolicy,
        )
        let limitedDelegate = URLSessionTaskMetricsDelegate(
            transportRequest: limitedRequest,
            initialRequest: initialRequest,
        )
        #expect(
            invokeRedirect(
                delegate: limitedDelegate,
                session: session,
                task: task,
                response: response,
                proposedRequest: proposedRequest,
            )?.url == proposedRequest.url,
        )
        #expect(
            invokeRedirect(
                delegate: limitedDelegate,
                session: session,
                task: task,
                response: response,
                proposedRequest: proposedRequest,
            ) == nil,
        )
        #expect(limitedDelegate.redirectLimitExceeded()?.maximumRedirects == 1)
        #expect(limitedDelegate.redirectLimitExceeded()?.lastResponse?.status.code == 302)

        let zeroLimitRequest = makeTransportRequest(
            initialURL: initialURL,
            policy: .follow(maximumRedirects: 0),
        )
        let zeroLimitDelegate = URLSessionTaskMetricsDelegate(
            transportRequest: zeroLimitRequest,
            initialRequest: initialRequest,
        )
        #expect(
            invokeRedirect(
                delegate: zeroLimitDelegate,
                session: session,
                task: task,
                response: response,
                proposedRequest: proposedRequest,
            ) == nil,
        )
        #expect(zeroLimitDelegate.redirectLimitExceeded()?.maximumRedirects == 0)

        let secondAttemptRequest = TransportRequest(
            httpRequest: limitedRequest.httpRequest,
            body: .none,
            redirectPolicy: limitedRequest.redirectPolicy,
            requestID: limitedRequest.requestID,
            requestContext: limitedRequest.requestContext,
            attemptNumber: 2,
        )
        let secondAttemptDelegate = URLSessionTaskMetricsDelegate(
            transportRequest: secondAttemptRequest,
            initialRequest: initialRequest,
        )
        #expect(
            invokeRedirect(
                delegate: secondAttemptDelegate,
                session: session,
                task: task,
                response: response,
                proposedRequest: proposedRequest,
            )?.url == proposedRequest.url,
        )
        #expect(secondAttemptDelegate.redirectLimitExceeded()?.maximumRedirects == nil)
        let recordedRedirects = redirectContexts.withLock { $0 }
        #expect(recordedRedirects.count == 3)
        #expect(recordedRedirects[0].attemptNumber == 1)
        #expect(recordedRedirects[0].redirectOrdinal == 1)
        #expect(recordedRedirects[1].attemptNumber == 1)
        #expect(recordedRedirects[1].redirectOrdinal == 2)
        #expect(recordedRedirects[2].attemptNumber == 2)
        #expect(recordedRedirects[2].redirectOrdinal == 1)
    }

    @Test("The selected client, endpoint, or request policy reaches each transport attempt")
    func resolvedPolicyReachesTransportWithReplacementPrecedence() async throws {
        let url = try #require(URL(string: "https://example.com/policy"))
        let clientPolicy = RedirectPolicy.reject(maximumRedirects: 1)
        let endpointPolicy = RedirectPolicy.follow(maximumRedirects: 2)
        let requestPolicy = RedirectPolicy.sameOriginOnly(maximumRedirects: 3)
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        let transport = RedirectPolicyRecordingTransport([
            successfulResult(statusCode: 200),
            successfulResult(statusCode: 200),
            successfulResult(statusCode: 200),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRedirectPolicy(clientPolicy),
        )

        _ = try await client.send(Request(endpoint: endpoint))
        _ = try await client.send(Request(endpoint: endpoint.redirectPolicy(endpointPolicy)))
        _ = try await client.send(
            Request(endpoint: endpoint.redirectPolicy(endpointPolicy)).redirectPolicy(requestPolicy),
        )

        let receivedRequests = await transport.receivedRequests()
        let sameOriginContext = try makeContext(
            currentURL: "https://example.com/start",
            proposedURL: "https://example.com/next",
        )
        let crossOriginContext = try makeContext(
            currentURL: "https://example.com/start",
            proposedURL: "https://other.example/next",
        )

        #expect(receivedRequests.count == 3)
        #expect(receivedRequests[0].redirectPolicy.maximumRedirects == 1)
        #expect(receivedRequests[0].redirectPolicy.decision(for: sameOriginContext) == .reject)
        #expect(receivedRequests[1].redirectPolicy.maximumRedirects == 2)
        #expect(receivedRequests[1].redirectPolicy.decision(for: sameOriginContext) == .follow)
        #expect(receivedRequests[2].redirectPolicy.maximumRedirects == 3)
        #expect(receivedRequests[2].redirectPolicy.decision(for: sameOriginContext) == .follow)
        #expect(receivedRequests[2].redirectPolicy.decision(for: crossOriginContext) == .reject)
        #expect(receivedRequests.map(\.attemptNumber) == [1, 1, 1])
    }

    @Test("A rejected redirect response continues through recovery retry validation and decoding")
    func rejectedRedirectResponseContinuesThroughResponsePipeline() async throws {
        let url = try #require(URL(string: "https://example.com/rejected"))
        let events = RedirectEventRecorder()
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.customDecision = { _ in
            events.append("retry")
            return .doNotRetry
        }
        let response = HTTPResponse(status: .init(code: 302))
        let transport = RedirectPolicyRecordingTransport([
            .success(data: Data([0x2a]), response: response, rawTaskMetrics: nil),
        ])
        let configuration = NetworkClient.Configuration()
            .withAuthenticationProvider(RedirectRecordingAuthenticationProvider(events: events))
            .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .custom { data, _ in
                events.append("decode")
                return data
            },
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        .redirectPolicy(.reject(maximumRedirects: 0))
        .validationPolicy(.custom { context in
            events.append("validate")
            return context.httpResponse.status.code == 302 ? .accept : .reject()
        })
        let client = try NetworkClient(transport: transport, configuration: configuration)

        let result = try await client.send(Request(endpoint: endpoint))

        #expect(result.httpResponse.status.code == 302)
        #expect(result.value == Data([0x2a]))
        #expect(result.attempts.map(\.outcome) == [.acceptedResponse])
        #expect(events.values == ["auth-adapt", "auth-recover", "retry", "validate", "decode"])
        let receivedRequests = await transport.receivedRequests()
        #expect(receivedRequests.count == 1)
        #expect(receivedRequests[0].redirectPolicy.maximumRedirects == 0)
    }

    @Test("Redirect-limit failure carries attempt history and bypasses recovery retry and decoding")
    func redirectLimitFailureBypassesResponseProcessing() async throws {
        let url = try #require(URL(string: "https://example.com/limited"))
        let events = RedirectEventRecorder()
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.customDecision = { context in
            events.append("retry")
            return context.attemptNumber == 1 ? .retry : .doNotRetry
        }
        let lastResponse = HTTPResponse(status: .init(code: 302))
        let transport = RedirectPolicyRecordingTransport([
            .success(
                data: Data(),
                response: HTTPResponse(status: .init(code: 503)),
                rawTaskMetrics: nil,
            ),
            .redirectLimitExceeded(
                maximumRedirects: 0,
                lastResponse: lastResponse,
                rawTaskMetrics: nil,
            ),
        ])
        let adapter = AnyRequestAdapter(adapt: { context in
            events.append("adapter")
            return context.request
        })
        let configuration = NetworkClient.Configuration()
            .withRequestAdapter(adapter)
            .withAuthenticationProvider(RedirectRecordingAuthenticationProvider(events: events))
            .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .custom { data, _ in
                events.append("decode")
                return data
            },
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        .redirectPolicy(.follow(maximumRedirects: 0))
        .validationPolicy(.custom { _ in
            events.append("validate")
            return .accept
        })
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let task = client.task(for: Request(endpoint: endpoint))

        do {
            _ = try await task.value
            Issue.record("Expected redirect-limit exhaustion to fail the logical request")
        } catch let error as RedirectError {
            switch error {
            case let .tooManyRedirects(requestID, maximumRedirects, response, attempts):
                #expect(requestID == task.requestID)
                #expect(maximumRedirects == 0)
                #expect(response?.status.code == 302)
                #expect(attempts.map(\.requestID) == [task.requestID, task.requestID])
                #expect(attempts.map(\.attemptNumber) == [1, 2])
                #expect(attempts.map(\.outcome) == [.retryScheduled, .redirectLimitExceeded])
            }
        }

        #expect(events.values == [
            "adapter",
            "auth-adapt",
            "auth-recover",
            "retry",
            "adapter",
            "auth-adapt",
        ])
        let receivedRequests = await transport.receivedRequests()
        #expect(receivedRequests.map(\.attemptNumber) == [1, 2])
        #expect(receivedRequests.map(\.redirectPolicy.maximumRedirects) == [0, 0])
    }

    @Test("Redirect limits reset for authentication replay attempts")
    func redirectLimitResetsForAuthenticationReplayAttempts() async throws {
        let url = try #require(URL(string: "https://example.com/auth-replay"))
        let events = RedirectEventRecorder()
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.customDecision = { _ in
            events.append("retry")
            return .retry
        }
        let transport = RedirectPolicyRecordingTransport([
            .success(
                data: Data(),
                response: HTTPResponse(status: .init(code: 401)),
                rawTaskMetrics: nil,
            ),
            .redirectLimitExceeded(
                maximumRedirects: 0,
                lastResponse: HTTPResponse(status: .init(code: 302)),
                rawTaskMetrics: nil,
            ),
        ])
        let configuration = NetworkClient.Configuration()
            .withAuthenticationProvider(
                RedirectRecordingAuthenticationProvider(events: events, recoveryDecisions: [.replay]),
            )
            .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .custom { data, _ in
                events.append("decode")
                return data
            },
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        .redirectPolicy(.follow(maximumRedirects: 0))
        .validationPolicy(.custom { _ in
            events.append("validate")
            return .accept
        })
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let task = client.task(for: Request(endpoint: endpoint))

        do {
            _ = try await task.value
            Issue.record("Expected redirect-limit exhaustion after authentication replay")
        } catch let error as RedirectError {
            switch error {
            case let .tooManyRedirects(requestID, maximumRedirects, response, attempts):
                #expect(requestID == task.requestID)
                #expect(maximumRedirects == 0)
                #expect(response?.status.code == 302)
                #expect(attempts.map(\.attemptNumber) == [1, 2])
                #expect(attempts.map(\.outcome) == [.authenticationReplayScheduled, .redirectLimitExceeded])
            }
        }

        #expect(events.values == ["auth-adapt", "auth-recover", "auth-adapt"])
        let receivedRequests = await transport.receivedRequests()
        #expect(receivedRequests.map(\.attemptNumber) == [1, 2])
        #expect(receivedRequests.map(\.redirectPolicy.maximumRedirects) == [0, 0])
    }

    private func makeContext(
        currentURL: String,
        proposedURL: String,
        currentMethod: String = "GET",
        proposedMethod: String = "GET",
        requestID: RequestID = RequestID(rawValue: UUID()),
        requestContext: RequestContext = RequestContext(),
        attemptNumber: UInt = 1,
        redirectOrdinal: UInt = 1,
    ) throws -> RedirectPolicy.Context {
        let sourceURL = try #require(URL(string: currentURL))
        let destinationURL = try #require(URL(string: proposedURL))
        var currentRequest = URLRequest(url: sourceURL)
        currentRequest.httpMethod = currentMethod
        var proposedRequest = URLRequest(url: destinationURL)
        proposedRequest.httpMethod = proposedMethod

        return RedirectPolicy.Context(
            currentRequest: currentRequest,
            proposedRequest: proposedRequest,
            httpResponse: HTTPResponse(status: .init(code: 302)),
            requestID: requestID,
            requestContext: requestContext,
            attemptNumber: attemptNumber,
            redirectOrdinal: redirectOrdinal,
        )
    }

    private func makeTransportRequest(
        initialURL: URL,
        policy: RedirectPolicy,
        requestID: RequestID = RequestID(rawValue: UUID()),
        requestContext: RequestContext = RequestContext(),
        attemptNumber: UInt = 1,
    ) -> TransportRequest {
        TransportRequest(
            httpRequest: HTTPRequest(method: .get, url: initialURL),
            body: .none,
            redirectPolicy: policy,
            requestID: requestID,
            requestContext: requestContext,
            attemptNumber: attemptNumber,
        )
    }

    private func successfulResult(statusCode: Int) -> NetworkTransportResult {
        .success(
            data: Data(),
            response: HTTPResponse(status: .init(code: statusCode)),
            rawTaskMetrics: nil,
        )
    }

    private func makeRedirectResponse(for url: URL) throws -> HTTPURLResponse {
        try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://example.com/next"],
            ),
        )
    }

    private func invokeRedirect(
        delegate: URLSessionTaskMetricsDelegate,
        session: URLSession,
        task: URLSessionDataTask,
        response: HTTPURLResponse,
        proposedRequest: URLRequest,
    ) -> URLRequest? {
        var forwardedRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest,
        ) { request in
            forwardedRequest = request
        }
        return forwardedRequest
    }
}

private actor RedirectPolicyRecordingTransport: NetworkTransport {
    private var results: [NetworkTransportResult]
    private var requests: [TransportRequest] = []

    init(_ results: [NetworkTransportResult]) {
        self.results = results
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw URLError(.unsupportedURL)
    }

    func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        requests.append(request)
        return results.removeFirst()
    }

    func receivedRequests() -> [TransportRequest] {
        requests
    }
}

private final class RedirectEventRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] {
        storage.withLock { $0 }
    }

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }
}

private struct RedirectRecordingAuthenticationProvider: AuthenticationProvider {
    let events: RedirectEventRecorder
    private let recoverySequence: RedirectRecoverySequence

    init(events: RedirectEventRecorder, recoveryDecisions: [AuthenticationRecovery] = [.doNotReplay]) {
        self.events = events
        recoverySequence = RedirectRecoverySequence(recoveryDecisions)
    }

    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        events.append("auth-adapt")
        return context.request
    }

    func recover(_: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        events.append("auth-recover")
        return recoverySequence.next()
    }
}

private final class RedirectRecoverySequence: Sendable {
    private let decisions: Mutex<[AuthenticationRecovery]>

    init(_ decisions: [AuthenticationRecovery]) {
        self.decisions = Mutex(decisions)
    }

    func next() -> AuthenticationRecovery {
        decisions.withLock { decisions in
            guard decisions.isEmpty == false else {
                return .doNotReplay
            }

            return decisions.removeFirst()
        }
    }
}

private enum RedirectTraceKey: RequestContextKey {
    typealias Value = String
}
