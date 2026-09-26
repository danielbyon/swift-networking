//
//  BodyEncodingAndResponseDecodingTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct BodyEncodingAndResponseDecodingTests {
    @Test("Bodyful data requests send raw bytes unchanged")
    func bodyfulDataRequestSendsRawBytesUnchanged() async throws {
        let payload = Data([0x00, 0x7f, 0xff])
        let url = try #require(URL(string: "https://example.com/upload"))
        let endpoint = Endpoint<String, Data, Data>.data(
            method: .post,
            route: .absolute(forInput: "route-witness") { _ in url },
            body: .data(contentType: nil),
            response: .data,
        )
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let request = Request(endpoint: endpoint, input: "42", body: payload)
            .queryItems([URLQueryItem(name: "trace", value: "1")])
            .header(.authorization, "request-token")

        let response = try await client.send(request)

        #expect(response.value == Data([0x2a]))
        let sentRequest = try #require(await (transport.recordedRequests()).first)
        #expect(sentRequest.httpRequest.url?.query == "trace=1")
        #expect(headerValues(.authorization, in: sentRequest.httpRequest.headerFields) == ["request-token"])
        #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields).isEmpty)
        if case let .data(bytes) = sentRequest.body {
            #expect(bytes == payload)
            let urlRequest = try #require(makeURLRequest(sentRequest, assumesHTTP3Capable: nil))
            #expect(urlRequest.httpBody == payload)
        } else {
            Issue.record("Expected the raw data body to reach the transport")
        }
    }

    @Test("Transport mapping leaves an absent body unset")
    func transportMappingLeavesAbsentBodyUnset() throws {
        let url = try #require(URL(string: "https://example.com/upload"))
        let request = TransportRequest(
            httpRequest: HTTPRequest(method: .post, url: url),
            body: .none,
        )

        let urlRequest = try #require(makeURLRequest(request, assumesHTTP3Capable: nil))

        #expect(urlRequest.httpBody == nil)
    }

    @Test("Raw body content type uses the lowest-precedence inference layer")
    func rawBodyContentTypeUsesLibraryInferenceLayer() async throws {
        let endpoint = try Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .data(contentType: "application/vnd.example+binary"),
            response: .data,
        )
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint, body: Data([1])))

        let sentRequest = try #require(await (transport.recordedRequests()).first)
        #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields) ==
            ["application/vnd.example+binary"])
    }

    @Test("Bodyful no-input requests use constant route and header state")
    func bodyfulNoInputRequestUsesConstantState() async throws {
        let fixedHeaders = makeFields((.authorization, "fixed-token"))
        let endpoint = try Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .data(),
            response: .data,
            query: .items([URLQueryItem(name: "fixed", value: "constant")]),
        )
        .headers(fixedHeaders)
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint, body: Data([1])))

        let sentRequest = try #require(await (transport.recordedRequests()).first)
        let expectedURL = try #require(URL(string: "https://example.com/body?fixed=constant"))
        #expect(sentRequest.httpRequest.url == expectedURL)
        #expect(headerValues(.authorization, in: sentRequest.httpRequest.headerFields) == ["fixed-token"])
    }

    @Test("JSON body and response codecs apply client then endpoint configuration per execution")
    func jsonCodecConfigurationsLayerAndRunForEachExecution() async throws {
        let encoderCalls = Mutex(0)
        let decoderCalls = Mutex(0)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = TimestampPayload(timestamp: timestamp)
        let endpoint = try Endpoint<Never, TimestampPayload, TimestampPayload>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .json(),
            response: .json(),
        )
        .jsonEncoderConfiguration { encoder in
            encoder.dateEncodingStrategy = .secondsSince1970
        }
        .jsonDecoderConfiguration { decoder in
            decoder.dateDecodingStrategy = .secondsSince1970
        }
        let configuration = NetworkClient.Configuration()
            .withJSONEncoderConfiguration { encoder in
                encoderCalls.withLock { $0 += 1 }
                encoder.dateEncodingStrategy = .iso8601
            }
            .withJSONDecoderConfiguration { decoder in
                decoderCalls.withLock { $0 += 1 }
                decoder.dateDecodingStrategy = .iso8601
            }
        let transport = BodyRecordingTransport(responseData: Data(#"{"timestamp":1700000000}"#.utf8))
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let request = Request(endpoint: endpoint, body: payload)

        let first = try await client.send(request)
        let second = try await client.send(request)

        #expect(first.value == payload)
        #expect(second.value == payload)
        #expect(encoderCalls.withLock { $0 } == 2)
        #expect(decoderCalls.withLock { $0 } == 2)
        let sentRequests = await transport.recordedRequests()
        #expect(sentRequests.count == 2)
        for sentRequest in sentRequests {
            #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields) == ["application/json"])
            #expect(headerValues(.accept, in: sentRequest.httpRequest.headerFields) == ["application/json"])
            if case let .data(bytes) = sentRequest.body {
                #expect(String(decoding: bytes, as: UTF8.self).contains("1700000000"))
            } else {
                Issue.record("Expected the JSON body to be encoded as in-memory bytes")
            }
        }
    }

    @Test("Chained endpoint encoder configurations compose")
    func chainedEndpointEncoderConfigurationsCompose() async throws {
        let payload = ChainedCodecPayload(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            displayName: "Ada",
        )
        let endpoint = try Endpoint<Never, ChainedCodecPayload, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .json(),
            response: .data,
        )
        .jsonEncoderConfiguration { $0.dateEncodingStrategy = .iso8601 }
        .jsonEncoderConfiguration { $0.keyEncodingStrategy = .convertToSnakeCase }
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint, body: payload))

        let sentRequest = try #require(await transport.recordedRequests().first)
        guard case let .data(bytes) = sentRequest.body else {
            Issue.record("Expected the JSON body to reach the transport")
            return
        }

        let json = String(decoding: bytes, as: UTF8.self)
        #expect(json.contains("\"created_at\":\"2023-11-14T22:13:20Z\""))
        #expect(json.contains("\"display_name\":\"Ada\""))
    }

    @Test("Chained endpoint decoder configurations compose")
    func chainedEndpointDecoderConfigurationsCompose() async throws {
        let expected = ChainedCodecPayload(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            displayName: "Ada",
        )
        let endpoint = try Endpoint<Never, Never, ChainedCodecPayload>.data(
            method: .get,
            route: .absolute(makeURL()),
            response: .json(),
        )
        .jsonDecoderConfiguration { $0.dateDecodingStrategy = .iso8601 }
        .jsonDecoderConfiguration { $0.keyDecodingStrategy = .convertFromSnakeCase }
        let responseData = Data(
            #"{"created_at":"2023-11-14T22:13:20Z","display_name":"Ada"}"#.utf8,
        )
        let transport = BodyRecordingTransport(responseData: responseData)
        let client = try NetworkClient(transport: transport)

        let response = try await client.send(Request(endpoint: endpoint))

        #expect(response.value == expected)
    }

    @Test("Inferred JSON headers yield to client endpoint and request headers")
    func inferredJSONHeadersYieldToExplicitLayers() async throws {
        let endpoint = try Endpoint<Never, TimestampPayload, CodablePayload>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .json(contentType: "application/x-inferred"),
            response: .json(),
        )
        let payload = TimestampPayload(timestamp: Date(timeIntervalSince1970: 0))
        let cases: [(HTTPFields, HTTPFields, HTTPFields, String, String)] = [
            (HTTPFields(), HTTPFields(), HTTPFields(), "application/x-inferred", "application/json"),
            (
                makeFields((.contentType, "application/x-client"), (.accept, "application/x-client")),
                HTTPFields(),
                HTTPFields(),
                "application/x-client",
                "application/x-client",
            ),
            (
                HTTPFields(),
                makeFields((.contentType, "application/x-endpoint"), (.accept, "application/x-endpoint")),
                HTTPFields(),
                "application/x-endpoint",
                "application/x-endpoint",
            ),
            (
                HTTPFields(),
                HTTPFields(),
                makeFields((.contentType, "application/x-request"), (.accept, "application/x-request")),
                "application/x-request",
                "application/x-request",
            ),
        ]

        for (clientFields, endpointFields, requestFields, expectedContentType, expectedAccept) in cases {
            let transport = BodyRecordingTransport(responseData: Data(#"{"value":1}"#.utf8))
            let client = try NetworkClient(
                transport: transport,
                configuration: .init().withDefaultHeaders(clientFields),
            )
            let request = Request(endpoint: endpoint.headers(endpointFields), body: payload).headers(requestFields)

            _ = try await client.send(request)

            let sentRequest = try #require(await (transport.recordedRequests()).first)
            #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields) == [expectedContentType])
            #expect(headerValues(.accept, in: sentRequest.httpRequest.headerFields) == [expectedAccept])
        }
    }

    @Test("Custom body encoding runs during execution and preserves thrown errors")
    func customBodyEncodingRunsDuringExecutionAndPropagatesErrors() async throws {
        let encodingCalls = Mutex(0)
        let encodingError = BodyTestError.encoding
        let endpoint = try Endpoint<Never, CustomBody, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .custom { body in
                encodingCalls.withLock { $0 += 1 }
                if body.shouldThrow {
                    throw encodingError
                }
                return body.bytes
            },
            response: .data,
        )
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let request = Request(
            endpoint: endpoint,
            body: CustomBody(bytes: Data([3, 4]), shouldThrow: false),
        )

        #expect(encodingCalls.withLock { $0 } == 0)
        _ = try await client.send(request)
        #expect(encodingCalls.withLock { $0 } == 1)
        let sentRequest = try #require(await (transport.recordedRequests()).first)
        #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields).isEmpty)
        if case let .data(bytes) = sentRequest.body {
            #expect(bytes == Data([3, 4]))
        } else {
            Issue.record("Expected the custom body encoder to provide in-memory bytes")
        }

        do {
            _ = try await client.send(Request(
                endpoint: endpoint,
                body: CustomBody(bytes: Data(), shouldThrow: true),
            ))
            Issue.record("Expected the custom encoder's error to propagate")
        } catch let error as BodyTestError {
            #expect(error == encodingError)
        }
        #expect(await transport.executionCount() == 1)
    }

    @Test("JSON encoding propagates native EncodingError before transport")
    func jsonEncodingPropagatesNativeErrorBeforeTransport() async throws {
        let endpoint = try Endpoint<Never, EncodingFailingBody, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .json(),
            response: .data,
        )
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let request = Request(endpoint: endpoint, body: EncodingFailingBody())

        do {
            _ = try await client.send(request)
            Issue.record("Expected the JSON encoder's native error to propagate")
        } catch let error as EncodingError {
            guard case let .invalidValue(value, context) = error else {
                Issue.record("Expected EncodingError.invalidValue")
                return
            }

            #expect(value as? String == "native-encoding-failure")
            #expect(context.debugDescription == "native encoding failure")
        }
        #expect(await transport.executionCount() == 0)
    }

    @Test("JSON decoding accepts valid bytes regardless of response media type")
    func jsonDecodingDoesNotValidateResponseContentType() async throws {
        let transport = BodyRecordingTransport(
            responseData: Data(#"{"value":7}"#.utf8),
            response: HTTPResponse(
                status: .init(code: 200),
                headerFields: HTTPFields([HTTPField(name: .contentType, value: "text/plain")]),
            ),
        )
        let client = try NetworkClient(transport: transport)
        let endpoint = try Endpoint<Never, Never, CodablePayload>.data(
            method: .get,
            route: .absolute(makeURL()),
            response: .json(),
        )

        let response = try await client.send(Request(endpoint: endpoint))

        #expect(response.value == CodablePayload(value: 7))
        let sentRequest = try #require(await (transport.recordedRequests()).first)
        #expect(headerValues(.accept, in: sentRequest.httpRequest.headerFields) == ["application/json"])

        let invalidJSONTransport = BodyRecordingTransport(responseData: Data("{".utf8))
        let invalidJSONClient = try NetworkClient(transport: invalidJSONTransport)
        do {
            _ = try await invalidJSONClient.send(Request(endpoint: endpoint))
            Issue.record("Expected malformed JSON bytes to produce the native decoding error")
        } catch is DecodingError {
            #expect(await invalidJSONTransport.executionCount() == 1)
        }
    }

    @Test("Custom response decoding receives response metadata and preserves thrown errors")
    func customResponseDecodingUsesMetadataAndPropagatesErrors() async throws {
        let responseError = BodyTestError.decoding
        let decoding = ResponseDecoding<CustomOutput>.custom { data, httpResponse in
            if httpResponse.status.code == 500 {
                throw responseError
            }
            return CustomOutput(byteCount: data.count, statusCode: httpResponse.status.code)
        }
        let transport = BodyRecordingTransport(responseData: Data([1, 2]))
        let client = try NetworkClient(transport: transport)
        let endpoint = try Endpoint<Never, Never, CustomOutput>.data(
            method: .get,
            route: .absolute(makeURL()),
            response: decoding,
        )
        .validationPolicy(.custom(validate: { _ in .accept }))

        #expect(
            try await client.send(Request(endpoint: endpoint)).value == CustomOutput(byteCount: 2, statusCode: 200),
        )

        let failingTransport = BodyRecordingTransport(
            responseData: Data(),
            response: HTTPResponse(status: .init(code: 500)),
        )
        let failingClient = try NetworkClient(transport: failingTransport)
        do {
            _ = try await failingClient.send(Request(endpoint: endpoint))
            Issue.record("Expected the custom decoder's error to propagate")
        } catch let error as BodyTestError {
            #expect(error == responseError)
        }
    }

    @Test("Empty response decoding defaults to ignore and can require empty bytes")
    func emptyResponsePoliciesAreExplicit() async throws {
        let encodedEmptyValue = try JSONEncoder().encode(EmptyResponse())
        #expect(try JSONDecoder().decode(EmptyResponse.self, from: encodedEmptyValue) == EmptyResponse())

        let endpoint = try Endpoint<Never, Never, EmptyResponse>.data(
            method: .get,
            route: .absolute(makeURL()),
            response: .empty(),
        )
        let nonemptyTransport = BodyRecordingTransport(responseData: Data([1]))
        let nonemptyClient = try NetworkClient(transport: nonemptyTransport)

        #expect(try await nonemptyClient.send(Request(endpoint: endpoint)).value == EmptyResponse())

        let emptyTransport = BodyRecordingTransport(responseData: Data())
        let emptyClient = try NetworkClient(transport: emptyTransport)
        let requireEmptyEndpoint = try Endpoint<Never, Never, EmptyResponse>.data(
            method: .get,
            route: .absolute(makeURL()),
            response: .empty(policy: .requireEmpty),
        )

        #expect(try await emptyClient.send(Request(endpoint: requireEmptyEndpoint)).value == EmptyResponse())

        let rejectTransport = BodyRecordingTransport(responseData: Data([1]))
        let rejectClient = try NetworkClient(transport: rejectTransport)
        do {
            _ = try await rejectClient.send(Request(endpoint: requireEmptyEndpoint))
            Issue.record("Expected nonempty response bytes to fail requireEmpty decoding")
        } catch let error as DecodingError {
            switch error {
            case .dataCorrupted:
                break
            default:
                Issue.record("Expected DecodingError.dataCorrupted for a nonempty body")
            }
        }
    }

    @Test("File-backed data requests retain their source and decode responses")
    func fileBodyRetainsMetadataAndReachesTransport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-\(UUID().uuidString).bin",
        )
        let sourceBytes = Data([0x5a, 0x00, 0xff])
        try sourceBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let body = try BodyEncoding<URL>.file(contentType: "application/x-file").prepare(
            url,
            clientJSONEncoderConfiguration: { _ in },
            endpointJSONEncoderConfiguration: { _ in },
        )
        guard case let .file(preparedURL, contentType) = body else {
            Issue.record("Expected file metadata to remain file-backed")
            return
        }

        #expect(preparedURL == url)
        #expect(contentType == "application/x-file")
        #expect(headerValues(.contentType, in: body.inferredHeaders) == ["application/x-file"])
        let requestURL = try #require(URL(string: "https://example.com/upload"))
        let httpRequest = HTTPRequest(method: .post, url: requestURL, headerFields: body.inferredHeaders)
        let urlRequest = try #require(
            makeURLRequest(
                TransportRequest(httpRequest: httpRequest, body: body.inspection),
                assumesHTTP3Capable: nil,
            ),
        )
        #expect(urlRequest.httpBody == nil)
        let overriddenFields = HeaderComposer.compose(
            libraryInferred: body.inferredHeaders,
            clientDefaults: makeFields((.contentType, "application/x-client")),
            endpoint: HTTPFields(),
            request: HTTPFields(),
        )
        #expect(headerValues(.contentType, in: overriddenFields) == ["application/x-client"])

        let endpoint = try Endpoint<Never, URL, Data>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .file(contentType: "application/x-file"),
            response: .data,
        )
        let transport = BodyRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let response = try await client.send(Request(endpoint: endpoint, body: url))

        #expect(response.value == Data([0x2a]))
        let sentRequest = try #require(await transport.recordedRequests().first)
        guard case let .file(sentURL) = sentRequest.body else {
            Issue.record("Expected the original file URL to reach transport")
            return
        }

        #expect(sentURL == url)
        #expect(await transport.executionCount() == 1)
    }

    @Test("Client JSON codec configuration survives every derived configuration modifier")
    func jsonCodecConfigurationSurvivesDerivedCopies() async throws {
        let encoderCalls = Mutex(0)
        let decoderCalls = Mutex(0)
        let base = NetworkClient.Configuration()
            .withJSONEncoderConfiguration { _ in encoderCalls.withLock { $0 += 1 } }
            .withJSONDecoderConfiguration { _ in decoderCalls.withLock { $0 += 1 } }
        let configuration = base
            .withDefaultHeaders(HTTPFields())
            .withDefaultQueryItems([])
            .withURLQueryEncoderConfiguration(.init())
            .withRequestIDGenerator(UUIDRequestIDGenerator())
            .withURLCache(nil)
            .withHTTPCookieStorage(nil)
            .withRequestTimeout(nil)
            .withResourceTimeout(nil)
            .withWaitsForConnectivity(nil)
            .withAllowsExpensiveNetworkAccess(nil)
            .withAllowsConstrainedNetworkAccess(nil)
            .withAllowsCellularAccess(nil)
            .withCachePolicy(nil)
            .withAssumesHTTP3Capable(nil)
        let transport = BodyRecordingTransport(responseData: Data(#"{"value":1}"#.utf8))
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let endpoint = try Endpoint<Never, CodablePayload, CodablePayload>.data(
            method: .post,
            route: .absolute(makeURL()),
            body: .json(),
            response: .json(),
        )

        _ = try await client.send(Request(endpoint: endpoint, body: CodablePayload(value: 1)))

        #expect(encoderCalls.withLock { $0 } == 1)
        #expect(decoderCalls.withLock { $0 } == 1)
    }
}

private struct CodablePayload: Codable, Sendable, Equatable {
    let value: Int
}

private struct TimestampPayload: Codable, Sendable, Equatable {
    let timestamp: Date
}

private struct ChainedCodecPayload: Codable, Sendable, Equatable {
    let createdAt: Date
    let displayName: String
}

private struct CustomBody: Sendable {
    let bytes: Data
    let shouldThrow: Bool
}

private struct CustomOutput: Sendable, Equatable {
    let byteCount: Int
    let statusCode: Int
}

private struct EncodingFailingBody: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(
            "native-encoding-failure",
            EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "native encoding failure"),
        )
    }
}

private enum BodyTestError: Error, Sendable, Equatable {
    case encoding
    case decoding
}

private func makeURL() throws -> URL {
    try #require(URL(string: "https://example.com/body"))
}

private func makeFields(_ fields: (HTTPField.Name, String)...) -> HTTPFields {
    HTTPFields(fields.map { HTTPField(name: $0.0, value: $0.1) })
}

private func headerValues(_ name: HTTPField.Name, in fields: HTTPFields) -> [String] {
    fields.filter { $0.name == name }.map(\.value)
}

private actor BodyRecordingTransport: NetworkTransport {
    private var requests: [TransportRequest] = []
    private let responseData: Data
    private let response: HTTPResponse

    init(
        responseData: Data = Data([0x2a]),
        response: HTTPResponse = HTTPResponse(status: .init(code: 200)),
    ) {
        self.responseData = responseData
        self.response = response
    }

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        return (responseData, response)
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }

    func executionCount() -> Int {
        requests.count
    }
}
