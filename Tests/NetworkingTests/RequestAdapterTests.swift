//
//  RequestAdapterTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct RequestAdapterTests {
    @Test("Prepared request bodies expose only their immutable inspection values")
    func preparedBodyInspectionCases() {
        let data = Data([1, 2, 3])
        let fileURL = URL(fileURLWithPath: "/tmp/request-body")
        let none: PreparedRequestBody = .none
        let dataBody: PreparedRequestBody = .data(data)
        let fileBody: PreparedRequestBody = .file(fileURL)

        if case .none = none {
        } else {
            Issue.record("Expected an absent body")
        }
        if case let .data(actualData) = dataBody {
            #expect(actualData == data)
        } else {
            Issue.record("Expected an in-memory body")
        }
        if case let .file(actualURL) = fileBody {
            #expect(actualURL == fileURL)
        } else {
            Issue.record("Expected a file-backed body")
        }
    }

    @Test("Concrete and closure adapters run in order with stable request metadata")
    func adaptersReceivePreviousRequestAndStableMetadata() async throws {
        let body = Data([4, 5, 6])
        let requestIDValue = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let requestID = RequestID(rawValue: requestIDValue)
        let transport = AdapterRecordingTransport()
        let configuration = NetworkClient.Configuration()
            .withRequestIDGenerator(FixedRequestIDGenerator(requestID: requestID))
            .withRequestAdapter(AnyRequestAdapter(FirstHeaderAdapter()))
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                guard case let .data(actualBody) = context.body,
                      actualBody == body,
                      context.requestID == requestID,
                      context.context[TraceKey.self] == "trace-17",
                      context.request.headerFields[fields: .accept].first?.value == "first"
                else {
                    throw AdapterTestError.unexpectedContext
                }

                var request = context.request
                request.headerFields[fields: .accept] = [HTTPField(name: .accept, value: "second")]
                return request
            }))
        let client = try NetworkClient(transport: transport, configuration: configuration)

        let request = try makeDataRequest(body: body)
        let response = try await client.send(request.context(TraceKey.self, value: "trace-17"))
        let sentRequest = try #require(await transport.recordedRequests().first)

        #expect(response.requestID == requestID)
        #expect(sentRequest.httpRequest.headerFields[fields: .accept].first?.value == "second")
        if case let .data(actualBody) = sentRequest.body {
            #expect(actualBody == body)
        } else {
            Issue.record("Expected the prepared body to reach transport")
        }
    }

    @Test("An adapter error propagates unchanged and prevents transport")
    func adapterFailureStopsBeforeTransport() async throws {
        let transport = AdapterRecordingTransport()
        let adapter = AnyRequestAdapter(adapt: { _ in throw AdapterTestError.stop })
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestAdapter(adapter),
        )
        let request = try makeDataRequest(body: Data([1]))

        do {
            _ = try await client.send(request)
            Issue.record("Expected the adapter error")
        } catch let error as AdapterTestError {
            #expect(error == .stop)
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("File-backed requests fail before invoking adapters")
    func fileBodyFailsBeforeAdapters() async throws {
        let adapterCalls = AdapterCallCounter()
        let transport = AdapterRecordingTransport()
        let adapter = AnyRequestAdapter(adapt: { context in
            await adapterCalls.increment()
            return context.request
        })
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestAdapter(adapter),
        )
        let uploadURL = try #require(URL(string: "https://example.com/upload"))
        let endpoint = Endpoint<Never, URL, Data>.data(
            method: .post,
            route: .absolute(uploadURL),
            body: .file(contentType: "application/octet-stream"),
            response: .data,
        )

        do {
            _ = try await client.send(Request(endpoint: endpoint, body: URL(fileURLWithPath: "/tmp/upload")))
            Issue.record("Expected file-backed body construction to fail")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unsupportedOperationBodyCombination)
            #expect(await adapterCalls.value == 0)
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Body encoding errors occur before adapters")
    func bodyEncodingFailureStopsBeforeAdapters() async throws {
        let adapterCalls = AdapterCallCounter()
        let transport = AdapterRecordingTransport()
        let adapter = AnyRequestAdapter(adapt: { context in
            await adapterCalls.increment()
            return context.request
        })
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestAdapter(adapter),
        )
        let encodeURL = try #require(URL(string: "https://example.com/encode"))
        let endpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(encodeURL),
            body: .custom(encode: { _ in throw AdapterTestError.stop }),
            response: .data,
        )

        do {
            _ = try await client.send(Request(endpoint: endpoint, body: Data()))
            Issue.record("Expected body encoding to fail")
        } catch let error as AdapterTestError {
            #expect(error == .stop)
        }

        #expect(await adapterCalls.value == 0)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Requests without adapters retain the prepared body and inferred headers")
    func noAdaptersKeepExistingTransportBehavior() async throws {
        let body = Data([8, 9])
        let transport = AdapterRecordingTransport()
        let client = try NetworkClient(transport: transport)

        let request = try makeDataRequest(body: body, contentType: "application/x-example")
        _ = try await client.send(request)

        let sentRequest = try #require(await transport.recordedRequests().first)
        if case let .data(actualBody) = sentRequest.body {
            #expect(actualBody == body)
        } else {
            Issue.record("Expected the prepared body to reach transport")
        }
        #expect(sentRequest.httpRequest.headerFields[fields: .contentType].first?.value == "application/x-example")
    }

    @Test("Body encoding completes before the first adapter runs")
    func bodyPreparationPrecedesAdapterExecution() async throws {
        let expectedBody = Data([2, 4, 6])
        let events = Mutex<[String]>([])
        let encodeURL = try #require(URL(string: "https://example.com/encode-before-adapt"))
        let endpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(encodeURL),
            body: .custom(encode: { body in
                events.withLock { $0.append("encoded") }
                return body
            }),
            response: .data,
        )
        let adapter = AnyRequestAdapter(adapt: { context in
            guard case let .data(body) = context.body,
                  body == expectedBody,
                  events.withLock({ $0 == ["encoded"] })
            else {
                throw AdapterTestError.unexpectedContext
            }

            events.withLock { $0.append("adapted") }
            return context.request
        })
        let transport = AdapterRecordingTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestAdapter(adapter),
        )

        _ = try await client.send(Request(endpoint: endpoint, body: expectedBody))

        #expect(events.withLock { $0 } == ["encoded", "adapted"])
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("Every configuration copy preserves the registered adapter order")
    func configurationCopiesPreserveAdapterOrder() async throws {
        let requestIDValue = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let requestID = RequestID(rawValue: requestIDValue)
        let baseConfiguration = NetworkClient.Configuration()
            .withRequestAdapter(FirstHeaderAdapter())
            .withRequestAdapter(SecondHeaderAdapter())
        let copies: [(NetworkClient.Configuration, expectedHeader: String)] = [
            (baseConfiguration.withDefaultQueryItems([]), "second"),
            (baseConfiguration.withURLQueryEncoderConfiguration(.init(arrayStrategy: .brackets)), "second"),
            (baseConfiguration.withJSONEncoderConfiguration { _ in }, "second"),
            (baseConfiguration.withJSONDecoderConfiguration { _ in }, "second"),
            (baseConfiguration.withRequestIDGenerator(FixedRequestIDGenerator(requestID: requestID)), "second"),
            (baseConfiguration.withDefaultHeaders(HTTPFields()), "second"),
            (baseConfiguration.withURLCache(nil), "second"),
            (baseConfiguration.withHTTPCookieStorage(nil), "second"),
            (baseConfiguration.withRequestTimeout(nil), "second"),
            (baseConfiguration.withResourceTimeout(nil), "second"),
            (baseConfiguration.withWaitsForConnectivity(nil), "second"),
            (baseConfiguration.withAllowsExpensiveNetworkAccess(nil), "second"),
            (baseConfiguration.withAllowsConstrainedNetworkAccess(nil), "second"),
            (baseConfiguration.withAllowsCellularAccess(nil), "second"),
            (baseConfiguration.withCachePolicy(nil), "second"),
            (baseConfiguration.withAssumesHTTP3Capable(nil), "second"),
            (baseConfiguration.withRequestAdapter(ThirdHeaderAdapter()), "third"),
        ]
        let requestURL = try #require(URL(string: "https://example.com/configured-adapters"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(requestURL),
            response: .data,
        )
        let request = Request(endpoint: endpoint)

        for (configuration, expectedHeader) in copies {
            let transport = AdapterRecordingTransport()
            let client = try NetworkClient(transport: transport, configuration: configuration)

            _ = try await client.send(request)

            let sentRequest = try #require(await transport.recordedRequests().first)
            #expect(sentRequest.httpRequest.headerFields[fields: .accept].first?.value == expectedHeader)
        }
    }

    private func makeDataRequest(body: Data, contentType: String? = nil) throws -> Request<Data> {
        let requestURL = try #require(URL(string: "https://example.com/adapt"))
        let endpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(requestURL),
            body: .data(contentType: contentType),
            response: .data,
        )
        return Request(endpoint: endpoint, body: body)
    }
}

private struct FirstHeaderAdapter: RequestAdapter {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        var request = context.request
        request.headerFields[fields: .accept] = [HTTPField(name: .accept, value: "first")]
        return request
    }
}

private struct SecondHeaderAdapter: RequestAdapter {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        guard context.request.headerFields[fields: .accept].first?.value == "first" else {
            throw AdapterTestError.unexpectedContext
        }

        var request = context.request
        request.headerFields[fields: .accept] = [HTTPField(name: .accept, value: "second")]
        return request
    }
}

private struct ThirdHeaderAdapter: RequestAdapter {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        guard context.request.headerFields[fields: .accept].first?.value == "second" else {
            throw AdapterTestError.unexpectedContext
        }

        var request = context.request
        request.headerFields[fields: .accept] = [HTTPField(name: .accept, value: "third")]
        return request
    }
}

private enum AdapterTestError: Error, Sendable, Equatable {
    case stop
    case unexpectedContext
}

private enum TraceKey: RequestContextKey {
    typealias Value = String
}

private struct FixedRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private actor AdapterRecordingTransport: NetworkTransport {
    private var requests: [TransportRequest] = []

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        return (Data(), HTTPResponse(status: .ok))
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }
}

private actor AdapterCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
