//
//  ResponseValidationAndBodyRetentionTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Synchronization
import Testing

struct ResponseValidationAndBodyRetentionTests {
    @Test("The default policy accepts only status codes from 200 through 299")
    func successfulStatusCodeBoundaries() async throws {
        let body = Data([0x01, 0x02])

        for (statusCode, shouldAccept) in [(199, false), (200, true), (299, true), (300, false)] {
            let transport = ValidationTestTransport(body: body, statusCode: statusCode)
            let client = try NetworkClient(transport: transport)
            let request = try Request(endpoint: makeDataEndpoint())

            if shouldAccept {
                let response = try await client.send(request)
                #expect(response.value == body)
                #expect(response.retainedBody == nil)
            } else {
                let error = try await validationError(from: client, request: request)
                #expect(error.httpResponse.status.code == statusCode)
                #expect(error.retainedBody?.data == body)
                #expect(error.retainedBody?.originalByteCount == Int64(body.count))
                #expect(error.retainedBody?.isTruncated == false)
            }
        }
    }

    @Test("Custom validation receives the exact response, request identity, context, and body")
    func customValidatorReceivesExecutionContext() async throws {
        let body = Data([0x00, 0x7f, 0xff])
        let requestID = RequestID(rawValue: UUID())
        let observations = Mutex<[ValidationObservation]>([])
        let policy = ResponseValidationPolicy.custom(validate: { context in
            let bodyMatches: Bool =
                switch context.receivedBody {
                case let .data(receivedData):
                    receivedData == body
                case .file:
                    false
                }
            observations.withLock { values in
                values.append(
                    ValidationObservation(
                        statusCode: context.httpResponse.status.code,
                        requestID: context.requestID,
                        trace: context.requestContext[RequestTraceKey.self],
                        bodyMatches: bodyMatches,
                    ),
                )
            }
            return .accept
        })
        let configuration = NetworkClient.Configuration()
            .withRequestIDGenerator(FixedValidationRequestIDGenerator(requestID: requestID))
            .withResponseValidationPolicy(policy)
        let transport = ValidationTestTransport(body: body, statusCode: 503)
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let request = try Request(endpoint: makeDataEndpoint())
            .context(RequestTraceKey.self, value: "profile-load")

        let response = try await client.send(request)

        #expect(response.value == body)
        #expect(observations.withLock { $0 } == [
            ValidationObservation(
                statusCode: 503,
                requestID: requestID,
                trace: "profile-load",
                bodyMatches: true,
            ),
        ])
    }

    @Test("Client, endpoint, and request policies replace lower-precedence policies")
    func validationPolicyReplacementPrecedence() async throws {
        let body = Data([0x2a])

        let clientCalls = CallCounter()
        let clientAccepts = ResponseValidationPolicy.custom(validate: { _ in
            clientCalls.increment()
            return .accept
        })
        let clientTransport = ValidationTestTransport(body: body, statusCode: 503)
        let client = try NetworkClient(
            transport: clientTransport,
            configuration: .init().withResponseValidationPolicy(clientAccepts),
        )
        let clientResponse = try await client.send(Request(endpoint: makeDataEndpoint()))
        #expect(clientResponse.value == body)
        #expect(clientCalls.value == 1)

        let rejectedClientCalls = CallCounter()
        let acceptedEndpointCalls = CallCounter()
        let rejectingClientPolicy = ResponseValidationPolicy.custom(validate: { _ in
            rejectedClientCalls.increment()
            return .reject(reason: "client")
        })
        let acceptingEndpointPolicy = ResponseValidationPolicy.custom(validate: { _ in
            acceptedEndpointCalls.increment()
            return .accept
        })
        let endpointTransport = ValidationTestTransport(body: body, statusCode: 503)
        let endpointClient = try NetworkClient(
            transport: endpointTransport,
            configuration: .init().withResponseValidationPolicy(rejectingClientPolicy),
        )
        let endpoint = try makeDataEndpoint().validationPolicy(acceptingEndpointPolicy)
        let endpointResponse = try await endpointClient.send(Request(endpoint: endpoint))
        #expect(endpointResponse.value == body)
        #expect(rejectedClientCalls.value == 0)
        #expect(acceptedEndpointCalls.value == 1)

        let lowerClientCalls = CallCounter()
        let lowerEndpointCalls = CallCounter()
        let requestCalls = CallCounter()
        let requestClient = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: .init().withResponseValidationPolicy(
                .custom(validate: { _ in
                    lowerClientCalls.increment()
                    return .reject(reason: "client")
                }),
            ),
        )
        let rejectingEndpoint = try makeDataEndpoint().validationPolicy(
            .custom(validate: { _ in
                lowerEndpointCalls.increment()
                return .reject(reason: "endpoint")
            }),
        )
        let acceptingRequest = Request(endpoint: rejectingEndpoint).validationPolicy(
            .custom(validate: { _ in
                requestCalls.increment()
                return .accept
            }),
        )

        let requestResponse = try await requestClient.send(acceptingRequest)
        #expect(requestResponse.value == body)
        #expect(lowerClientCalls.value == 0)
        #expect(lowerEndpointCalls.value == 0)
        #expect(requestCalls.value == 1)
    }

    @Test("Rejection skips decoding and retains the full diagnostic body by default")
    func rejectionSkipsDecodingAndRetainsErrorBody() async throws {
        let body = Data([0xde, 0xad, 0xbe, 0xef])
        let decoderCalls = CallCounter()
        let endpoint = try makeEndpoint(
            response: ResponseDecoding<Data>.custom(decode: { _, _ in
                decoderCalls.increment()
                return Data([0x01])
            }),
        )
        let policy = ResponseValidationPolicy.custom(validate: { _ in
            .reject(reason: "service unavailable")
        })
        let configuration = NetworkClient.Configuration()
            .withSuccessfulResponseBodyRetentionPolicy(.none)
            .withResponseValidationPolicy(policy)
        let client = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: configuration,
        )
        let request = Request(endpoint: endpoint)
        let task = client.task(for: request)

        let error = try await validationError(from: task)

        #expect(decoderCalls.value == 0)
        #expect(error.requestID == task.requestID)
        #expect(error.httpResponse.status.code == 503)
        #expect(error.reason == "service unavailable")
        #expect(error.retainedBody?.data == body)
        #expect(error.retainedBody?.originalByteCount == Int64(body.count))
        #expect(error.retainedBody?.isTruncated == false)
    }

    @Test("Accepted responses preserve decoder errors")
    func acceptedResponsePropagatesDecoderError() async throws {
        let endpoint = try makeEndpoint(
            response: ResponseDecoding<Data>.custom(decode: { _, _ in
                throw DecoderTestError.expected
            }),
        )
        let client = try NetworkClient(
            transport: ValidationTestTransport(body: Data([0x01]), statusCode: 200),
        )

        do {
            _ = try await client.send(Request(endpoint: endpoint))
            Issue.record("Expected the decoder error to propagate")
        } catch let error as DecoderTestError {
            #expect(error == .expected)
        }
    }

    @Test("Successful body retention keeps only the configured prefix and reports exact metadata")
    func successfulBodyRetentionPolicies() async throws {
        let scenarios = [
            RetentionScenario(body: Data([0x01]), policy: .none, expectedBytes: nil, truncated: nil),
            RetentionScenario(
                body: Data([0x01, 0x02, 0x03]),
                policy: .unlimited,
                expectedBytes: Data([0x01, 0x02, 0x03]),
                truncated: false,
            ),
            RetentionScenario(
                body: Data([0x01, 0x02]),
                policy: .upTo(3),
                expectedBytes: Data([0x01, 0x02]),
                truncated: false,
            ),
            RetentionScenario(
                body: Data([0x01, 0x02, 0x03]),
                policy: .upTo(3),
                expectedBytes: Data([0x01, 0x02, 0x03]),
                truncated: false,
            ),
            RetentionScenario(
                body: Data([0x01, 0x02, 0x03, 0x04]),
                policy: .upTo(3),
                expectedBytes: Data([0x01, 0x02, 0x03]),
                truncated: true,
            ),
            RetentionScenario(body: Data([0x01, 0x02]), policy: .upTo(0), expectedBytes: Data(), truncated: true),
            RetentionScenario(body: Data([0x01, 0x02]), policy: .upTo(-4), expectedBytes: Data(), truncated: true),
            RetentionScenario(body: Data(), policy: .upTo(0), expectedBytes: Data(), truncated: false),
            RetentionScenario(
                body: Data(repeating: 0xa5, count: 100_000),
                policy: .upTo(8),
                expectedBytes: Data(repeating: 0xa5, count: 8),
                truncated: true,
            ),
        ]

        for scenario in scenarios {
            let client = try NetworkClient(
                transport: ValidationTestTransport(body: scenario.body, statusCode: 200),
                configuration: .init().withSuccessfulResponseBodyRetentionPolicy(scenario.policy),
            )

            let response = try await client.send(Request(endpoint: makeDataEndpoint()))

            guard let expectedBytes = scenario.expectedBytes else {
                #expect(response.retainedBody == nil)
                continue
            }
            guard let retainedBody = response.retainedBody else {
                Issue.record("Expected the configured successful body prefix")
                continue
            }

            #expect(retainedBody.data == expectedBytes)
            #expect(retainedBody.data.count <= expectedBytes.count)
            #expect(retainedBody.originalByteCount == Int64(scenario.body.count))
            #expect(retainedBody.isTruncated == scenario.truncated)
        }
    }

    @Test("File retention preserves bounded prefixes and zero or negative limits")
    func fileBodyRetentionPolicies() throws {
        let source = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let fileURL = try makeRetentionTestFile(source)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-missing-\(UUID().uuidString)",
        )

        let noRetainedBody = try BodyRetentionPolicy.none.retain(fileAt: missingURL)
        #expect(noRetainedBody == nil)

        let boundedValue = try BodyRetentionPolicy.upTo(2).retain(fileAt: fileURL)
        let bounded = try #require(boundedValue)
        #expect(bounded.data == Data([0x10, 0x20]))
        #expect(bounded.originalByteCount == Int64(source.count))
        #expect(bounded.isTruncated)

        let zeroValue = try BodyRetentionPolicy.upTo(0).retain(fileAt: fileURL)
        let zero = try #require(zeroValue)
        #expect(zero.data.isEmpty)
        #expect(zero.originalByteCount == Int64(source.count))
        #expect(zero.isTruncated)

        let negativeValue = try BodyRetentionPolicy.upTo(-4).retain(fileAt: fileURL)
        let negative = try #require(negativeValue)
        #expect(negative.data.isEmpty)
        #expect(negative.originalByteCount == Int64(source.count))
        #expect(negative.isTruncated)

        let unlimitedValue = try BodyRetentionPolicy.unlimited.retain(fileAt: fileURL)
        let unlimited = try #require(unlimitedValue)
        #expect(unlimited.data == source)
        #expect(unlimited.originalByteCount == Int64(source.count))
        #expect(unlimited.isTruncated == false)
    }

    @Test("Retention policies replace independently at client, endpoint, and request levels")
    func retentionPolicyReplacementPrecedence() async throws {
        let body = Data([0x10, 0x20, 0x30, 0x40])
        let clientConfiguration = NetworkClient.Configuration()
            .withSuccessfulResponseBodyRetentionPolicy(.upTo(1))
            .withValidationErrorBodyRetentionPolicy(.upTo(1))

        let clientSuccess = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 200),
            configuration: clientConfiguration,
        )
        let clientResponse = try await clientSuccess.send(Request(endpoint: makeDataEndpoint()))
        #expect(clientResponse.retainedBody?.data == Data([0x10]))

        let endpointSuccess = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 200),
            configuration: clientConfiguration,
        )
        let endpoint = try makeDataEndpoint().successfulResponseBodyRetentionPolicy(.upTo(2))
        let endpointResponse = try await endpointSuccess.send(Request(endpoint: endpoint))
        #expect(endpointResponse.retainedBody?.data == Data([0x10, 0x20]))

        let requestSuccess = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 200),
            configuration: clientConfiguration,
        )
        let request = Request(endpoint: endpoint).successfulResponseBodyRetentionPolicy(.upTo(3))
        let requestResponse = try await requestSuccess.send(request)
        #expect(requestResponse.retainedBody?.data == Data([0x10, 0x20, 0x30]))

        let clientErrorClient = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: clientConfiguration,
        )
        let clientError = try await validationError(
            from: clientErrorClient,
            request: Request(endpoint: makeDataEndpoint()),
        )
        #expect(clientError.retainedBody?.data == Data([0x10]))

        let endpointErrorClient = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: clientConfiguration,
        )
        let endpointErrorEndpoint = try makeDataEndpoint().validationErrorBodyRetentionPolicy(.upTo(2))
        let endpointError = try await validationError(
            from: endpointErrorClient,
            request: Request(endpoint: endpointErrorEndpoint),
        )
        #expect(endpointError.retainedBody?.data == Data([0x10, 0x20]))

        let requestErrorClient = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: clientConfiguration,
        )
        let requestErrorRequest = Request(endpoint: endpointErrorEndpoint)
            .validationErrorBodyRetentionPolicy(.upTo(3))
        let requestError = try await validationError(from: requestErrorClient, request: requestErrorRequest)
        #expect(requestError.retainedBody?.data == Data([0x10, 0x20, 0x30]))

        let independentChannels = try NetworkClient(
            transport: ValidationTestTransport(body: body, statusCode: 503),
            configuration: .init()
                .withSuccessfulResponseBodyRetentionPolicy(.unlimited)
                .withValidationErrorBodyRetentionPolicy(.none),
        )
        let independentError = try await validationError(
            from: independentChannels,
            request: Request(endpoint: makeDataEndpoint()),
        )
        #expect(independentError.retainedBody == nil)
    }

    @Test("Client policy copies preserve policies, headers, queries, and request adapters")
    func clientConfigurationCopiesPreservePoliciesAndExistingState() async throws {
        let body = Data([0x01, 0x02, 0x03])
        let adapterCalls = CallCounter()
        let policy = ResponseValidationPolicy.custom(validate: { _ in .accept })
        var defaultHeaders = HTTPFields()
        defaultHeaders[fields: .accept] = [HTTPField(name: .accept, value: "application/example")]
        let adapter = AnyRequestAdapter(adapt: { context in
            adapterCalls.increment()
            var request = context.request
            request.headerFields[fields: .authorization] = [
                HTTPField(name: .authorization, value: "adapter"),
            ]
            return request
        })
        let baseURL = try #require(URL(string: "https://example.com/api"))
        let configuration = NetworkClient.Configuration(baseURL: baseURL)
            .withResponseValidationPolicy(policy)
            .withSuccessfulResponseBodyRetentionPolicy(.upTo(2))
            .withValidationErrorBodyRetentionPolicy(.upTo(1))
            .withDefaultHeaders(defaultHeaders)
            .withDefaultQueryItems([URLQueryItem(name: "client", value: "present")])
            .withRequestAdapter(adapter)
        let transport = ValidationTestTransport(body: body, statusCode: 503)
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "response-validation", makePath: { [$0] }),
            response: .data,
        )

        let response = try await client.send(Request(endpoint: endpoint, input: "response-validation"))

        #expect(response.value == body)
        #expect(response.retainedBody?.data == Data([0x01, 0x02]))
        #expect(adapterCalls.value == 1)
        let sentRequest = try #require(await transport.requests().first)
        #expect(sentRequest.httpRequest.url?.query == "client=present")
        #expect(sentRequest.httpRequest.headerFields[fields: .accept].first?.value == "application/example")
        #expect(sentRequest.httpRequest.headerFields[fields: .authorization].first?.value == "adapter")
    }

    @Test("Endpoint policy copies preserve body encoding and decoder configuration")
    func endpointPolicyCopiesPreserveBodyAndDecoderConfiguration() async throws {
        let url = try #require(URL(string: "https://example.com/endpoint-policy"))
        let body = JSONRequestBody(zulu: 2, alpha: 1)
        let responseBody = Data(#"{"record_id":7}"#.utf8)
        let clientPolicy = ResponseValidationPolicy.custom(validate: { _ in
            .reject(reason: "client")
        })
        var endpointHeaders = HTTPFields()
        endpointHeaders[fields: .accept] = [HTTPField(name: .accept, value: "application/endpoint")]
        let endpoint = Endpoint<Never, JSONRequestBody, JSONResponseValue>.data(
            method: .post,
            route: .absolute(url),
            body: .json(),
            response: .json(),
            query: .items([URLQueryItem(name: "endpoint", value: "present")]),
        )
        .validationPolicy(.custom(validate: { _ in .accept }))
        .successfulResponseBodyRetentionPolicy(.upTo(2))
        .validationErrorBodyRetentionPolicy(.upTo(1))
        .headers(endpointHeaders)
        .header(.accept, "application/endpoint-final")
        .jsonEncoderConfiguration { encoder in
            encoder.outputFormatting = [.sortedKeys]
        }
        .jsonDecoderConfiguration { decoder in
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        let configuration = NetworkClient.Configuration()
            .withResponseValidationPolicy(clientPolicy)
        let transport = ValidationTestTransport(body: responseBody, statusCode: 503)
        let client = try NetworkClient(transport: transport, configuration: configuration)

        let response = try await client.send(Request(endpoint: endpoint, body: body))

        #expect(response.value.recordID == 7)
        #expect(response.retainedBody?.data == Data([0x7b, 0x22]))
        let sentRequest = try #require(await transport.requests().first)
        #expect(sentRequest.httpRequest.url?.query == "endpoint=present")
        #expect(sentRequest.httpRequest.headerFields[fields: .accept].first?.value == "application/endpoint-final")
        if case let .data(encodedBody) = sentRequest.body {
            #expect(String(decoding: encodedBody, as: UTF8.self) == #"{"alpha":1,"zulu":2}"#)
        } else {
            Issue.record("Expected the encoded JSON request body")
        }
    }

    @Test("Request policy copies preserve request context, headers, queries, and both retention policies")
    func requestPolicyCopiesPreserveRequestState() async throws {
        let body = Data([0x11, 0x22, 0x33])
        let clientPolicy = ResponseValidationPolicy.custom(validate: { _ in
            .reject(reason: "client")
        })
        let endpoint = try makeDataEndpoint().validationPolicy(
            .custom(validate: { _ in .reject(reason: "endpoint") }),
        )
        let observations = Mutex<[String?]>([])
        let requestPolicy = ResponseValidationPolicy.custom(validate: { context in
            observations.withLock { $0.append(context.requestContext[RequestTraceKey.self]) }
            return context.requestContext[RequestTraceKey.self] == "request-copy" ? .accept : .reject()
        })
        var requestHeaders = HTTPFields()
        requestHeaders[fields: .accept] = [HTTPField(name: .accept, value: "application/request")]
        let request = Request(endpoint: endpoint)
            .validationPolicy(requestPolicy)
            .successfulResponseBodyRetentionPolicy(.upTo(2))
            .validationErrorBodyRetentionPolicy(.upTo(1))
            .context(RequestTraceKey.self, value: "request-copy")
            .queryItems([URLQueryItem(name: "request", value: "present")])
            .headers(requestHeaders)
            .header(.authorization, "request")
        let transport = ValidationTestTransport(body: body, statusCode: 503)
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withResponseValidationPolicy(clientPolicy),
        )

        let response = try await client.send(request)

        #expect(response.value == body)
        #expect(response.retainedBody?.data == Data([0x11, 0x22]))
        #expect(observations.withLock { $0 } == ["request-copy"])
        let sentRequest = try #require(await transport.requests().first)
        #expect(sentRequest.httpRequest.url?.query == "request=present")
        #expect(sentRequest.httpRequest.headerFields[fields: .accept].first?.value == "application/request")
        #expect(sentRequest.httpRequest.headerFields[fields: .authorization].first?.value == "request")
    }

    @Test("Response equality and hashing include retained-body metadata")
    func responseEqualityAndHashingIncludeRetainedBody() async throws {
        let endpoint = try makeEndpoint(
            response: ResponseDecoding<Data>.custom(decode: { _, _ in Data([0x7f]) }),
        )
        let requestID = RequestID(rawValue: UUID())
        let configuration = NetworkClient.Configuration()
            .withRequestIDGenerator(FixedValidationRequestIDGenerator(requestID: requestID))
            .withSuccessfulResponseBodyRetentionPolicy(.upTo(2))
        let firstClient = try NetworkClient(
            transport: ValidationTestTransport(body: Data([0x01, 0x02, 0x03]), statusCode: 200),
            configuration: configuration,
        )
        let secondClient = try NetworkClient(
            transport: ValidationTestTransport(body: Data([0x01, 0x02, 0x03, 0x04]), statusCode: 200),
            configuration: configuration,
        )

        let first = try await firstClient.send(Request(endpoint: endpoint))
        let second = try await secondClient.send(Request(endpoint: endpoint))

        #expect(first.value == second.value)
        #expect(first.requestID == second.requestID)
        #expect(first.retainedBody?.data == second.retainedBody?.data)
        #expect(first.retainedBody?.originalByteCount == 3)
        #expect(second.retainedBody?.originalByteCount == 4)
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }
}

private struct ValidationObservation: Sendable, Equatable {
    let statusCode: Int
    let requestID: RequestID
    let trace: String?
    let bodyMatches: Bool
}

private struct RetentionScenario {
    let body: Data
    let policy: BodyRetentionPolicy
    let expectedBytes: Data?
    let truncated: Bool?
}

private struct JSONRequestBody: Encodable, Sendable {
    let zulu: Int
    let alpha: Int
}

private struct JSONResponseValue: Decodable, Sendable {
    let recordID: Int

    private enum CodingKeys: String, CodingKey {
        case recordID = "recordId"
    }
}

private enum RequestTraceKey: RequestContextKey {
    typealias Value = String
}

private enum DecoderTestError: Error, Sendable, Equatable {
    case expected
}

private enum UnexpectedValidationSuccess: Error, Sendable {
    case requestWasAccepted
}

private struct FixedValidationRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private final class CallCounter: Sendable {
    private let state = Mutex(0)

    var value: Int {
        state.withLock { $0 }
    }

    func increment() {
        state.withLock { $0 += 1 }
    }
}

private actor ValidationTestTransport: NetworkTransport {
    private let body: Data
    private let httpResponse: HTTPResponse
    private var recordedRequests: [TransportRequest] = []

    init(body: Data, statusCode: Int) {
        self.body = body
        httpResponse = HTTPResponse(status: .init(code: statusCode))
    }

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        recordedRequests.append(request)
        return (body, httpResponse)
    }

    func requests() -> [TransportRequest] {
        recordedRequests
    }
}

private func makeDataEndpoint() throws -> Endpoint<Never, Never, Data> {
    try makeEndpoint(response: ResponseDecoding<Data>.data)
}

private func makeRetentionTestFile(_ data: Data) throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-networking-retention-\(UUID().uuidString)",
    )
    try data.write(to: fileURL)
    return fileURL
}

private func makeEndpoint<Output: Sendable>(
    response: ResponseDecoding<Output>,
) throws -> Endpoint<Never, Never, Output> {
    let url = try #require(URL(string: "https://example.com/response-validation"))
    return Endpoint<Never, Never, Output>.data(
        method: .get,
        route: .absolute(url),
        response: response,
    )
}

private func validationError(
    from client: NetworkClient,
    request: Request<some Sendable>,
) async throws -> ResponseValidationError {
    try await validationError(from: client.task(for: request))
}

private func validationError(
    from task: NetworkTask<some Sendable>,
) async throws -> ResponseValidationError {
    do {
        _ = try await task.value
    } catch let error as ResponseValidationError {
        return error
    }
    throw UnexpectedValidationSuccess.requestWasAccepted
}
