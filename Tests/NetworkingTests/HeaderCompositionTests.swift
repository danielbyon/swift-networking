//
//  HeaderCompositionTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import SnapshotTesting
import Synchronization
import Testing
@testable import Networking

@Suite(.serialized, .snapshots(record: .missing))
struct HeaderCompositionTests {
    @Test
    func inferredAcceptAndContentTypeFollowLayerPrecedence() throws {
        let accept = try makeHeaderName("Accept")
        let contentType = try makeHeaderName("Content-Type")
        let inferred = makeHeaderFields(
            (accept, "application/json"),
            (contentType, "application/json"),
        )
        let client = makeHeaderFields(
            (accept, "application/vnd.client+json"),
            (contentType, "application/vnd.client+json"),
        )
        let endpoint = makeHeaderFields(
            (accept, "application/vnd.endpoint+json"),
            (contentType, "application/vnd.endpoint+json"),
        )
        let request = makeHeaderFields(
            (accept, "application/vnd.request+json"),
            (contentType, "application/vnd.request+json"),
        )

        let inferredResult = HeaderComposer.compose(
            libraryInferred: inferred,
            clientDefaults: HTTPFields(),
            endpoint: HTTPFields(),
            request: HTTPFields(),
        )
        let clientResult = HeaderComposer.compose(
            libraryInferred: inferred,
            clientDefaults: client,
            endpoint: HTTPFields(),
            request: HTTPFields(),
        )
        let endpointResult = HeaderComposer.compose(
            libraryInferred: inferred,
            clientDefaults: client,
            endpoint: endpoint,
            request: HTTPFields(),
        )
        let requestResult = HeaderComposer.compose(
            libraryInferred: inferred,
            clientDefaults: client,
            endpoint: endpoint,
            request: request,
        )

        #expect(headerValues(accept, in: inferredResult) == ["application/json"])
        #expect(headerValues(contentType, in: inferredResult) == ["application/json"])
        #expect(headerValues(accept, in: clientResult) == ["application/vnd.client+json"])
        #expect(headerValues(contentType, in: clientResult) == ["application/vnd.client+json"])
        #expect(headerValues(accept, in: endpointResult) == ["application/vnd.endpoint+json"])
        #expect(headerValues(contentType, in: endpointResult) == ["application/vnd.endpoint+json"])
        #expect(headerValues(accept, in: requestResult) == ["application/vnd.request+json"])
        #expect(headerValues(contentType, in: requestResult) == ["application/vnd.request+json"])
    }

    @Test
    func transportReceivesPrecedenceOverridesRepeatedValuesAndContentLength() async throws {
        let transport = HeaderRecordingTransport()
        let layer = try makeHeaderName("X-Layer")
        let repeated = try makeHeaderName("X-Repeated")
        let endpointOverlay = try makeHeaderName("X-Endpoint-Overlay")
        let clientOnly = try makeHeaderName("X-Client-Only")
        let endpointOnly = try makeHeaderName("X-Endpoint-Only")
        let requestOnly = try makeHeaderName("X-Request-Only")
        let discarded = try makeHeaderName("X-Discarded")
        let added = try makeHeaderName("X-Added")
        let contentLength = HTTPField.Name.contentLength
        let endpointBuilderCalls = Mutex(0)
        let routeURL = try makeHeaderURL("https://example.com/headers")
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withDefaultHeaders(makeHeaderFields(
                (layer, "client"),
                (repeated, "client-first"),
                (repeated, "client-second"),
                (contentLength, "client-length"),
                (clientOnly, "client-value"),
            )),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "route-witness") { _ in
                routeURL
            },
            response: .data,
        )
        .headers { input in
            endpointBuilderCalls.withLock { $0 += 1 }
            return makeHeaderFields(
                (layer, "endpoint-builder"),
                (repeated, "endpoint-first"),
                (repeated, "endpoint-second"),
                (endpointOverlay, "builder-first"),
                (endpointOverlay, "builder-second"),
                (endpointOnly, input),
            )
        }
        .header(endpointOverlay, "endpoint-single")

        let request = Request(endpoint: endpoint, input: "captured")
            .headers(makeHeaderFields((discarded, "old-layer")))
            .headers(makeHeaderFields(
                (layer, "request"),
                (repeated, "request-first"),
                (repeated, "request-second"),
                (contentLength, "request-length"),
                (requestOnly, "request-value"),
            ))
            .header(added, "added-value")

        #expect(endpointBuilderCalls.withLock { $0 } == 1)

        for _ in 0 ..< 2 {
            _ = try await client.send(request)
        }

        let requests = await transport.receivedRequests()
        #expect(endpointBuilderCalls.withLock { $0 } == 1)
        #expect(requests.count == 2)
        for received in requests {
            let fields = received.headerFields
            #expect(headerValues(layer, in: fields) == ["request"])
            #expect(headerValues(repeated, in: fields) == ["request-first", "request-second"])
            #expect(headerValues(endpointOverlay, in: fields) == ["endpoint-single"])
            #expect(headerValues(contentLength, in: fields) == ["request-length"])
            #expect(headerValues(clientOnly, in: fields) == ["client-value"])
            #expect(headerValues(endpointOnly, in: fields) == ["captured"])
            #expect(headerValues(requestOnly, in: fields) == ["request-value"])
            #expect(headerValues(added, in: fields) == ["added-value"])
            #expect(headerValues(discarded, in: fields).isEmpty)
        }
        assertSnapshot(of: requests[0].headerFields, as: .json)
    }

    @Test
    func inputDerivedEndpointHeadersAreCapturedOnceWhenRequestBindsInput() async throws {
        let transport = HeaderRecordingTransport()
        let builderCalls = Mutex(0)
        let inputDerived = try makeHeaderName("X-Input-Derived")
        let replacedFixed = try makeHeaderName("X-Replaced-Fixed")
        let routeURL = try makeHeaderURL("https://example.com/headers-once")
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "route-witness") { _ in
                routeURL
            },
            response: .data,
        )
        .headers(makeHeaderFields((replacedFixed, "fixed-recipe")))
        .headers { input in
            builderCalls.withLock { $0 += 1 }
            return makeHeaderFields((inputDerived, input), (replacedFixed, "builder-recipe"))
        }
        let request = Request(endpoint: endpoint, input: "bound-value")

        #expect(builderCalls.withLock { $0 } == 1)
        let client = try NetworkClient(transport: transport)
        _ = try await client.send(request)
        _ = try await client.send(request)

        let requests = await transport.receivedRequests()
        #expect(builderCalls.withLock { $0 } == 1)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { headerValues(inputDerived, in: $0.headerFields) == ["bound-value"] })
        #expect(requests.allSatisfy { headerValues(replacedFixed, in: $0.headerFields) == ["builder-recipe"] })
    }

    @Test
    func noInputEndpointUsesFixedHeadersAndFieldConvenienceReplacesOneName() async throws {
        let transport = HeaderRecordingTransport()
        let replaced = try makeHeaderName("X-Replaced")
        let preserved = try makeHeaderName("X-Preserved")
        let discarded = try makeHeaderName("X-Discarded")
        let added = try makeHeaderName("X-Added")
        let requestOverride = try makeHeaderName("X-Request-Override")
        let routeURL = try makeHeaderURL("https://example.com/fixed-headers")
        let originalEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(routeURL),
            response: .data,
        )
        .headers(makeHeaderFields((discarded, "replaced-endpoint-recipe")))
        .headers(makeHeaderFields(
            (replaced, "old-first"),
            (replaced, "old-second"),
            (preserved, "kept"),
        ))
        let endpoint = originalEndpoint.header(replaced, "endpoint-replacement")
        let baseRequest = Request(endpoint: endpoint)
        let request = baseRequest
            .headers(makeHeaderFields(
                (discarded, "old-layer"),
                (replaced, "request-old-first"),
                (replaced, "request-old-second"),
                (requestOverride, "removed-by-replacement"),
            ))
            .headers(makeHeaderFields(
                (replaced, "request-before-single"),
                (added, "kept-in-request-layer"),
            ))
            .queryItems([URLQueryItem(name: "preserved-query", value: "yes")])
            .header(replaced, "request-replacement")

        let client = try NetworkClient(transport: transport)
        _ = try await client.send(Request(endpoint: originalEndpoint))
        _ = try await client.send(baseRequest)
        _ = try await client.send(request)

        let requests = await transport.receivedRequests()
        let originalFields = try #require(requests.first?.headerFields)
        let baseRequestFields = try #require(requests.dropFirst().first?.headerFields)
        let derivedFields = try #require(requests.last?.headerFields)
        #expect(headerValues(replaced, in: originalFields) == ["old-first", "old-second"])
        #expect(headerValues(discarded, in: originalFields).isEmpty)
        #expect(headerValues(replaced, in: baseRequestFields) == ["endpoint-replacement"])
        #expect(headerValues(added, in: baseRequestFields).isEmpty)
        #expect(headerValues(replaced, in: derivedFields) == ["request-replacement"])
        #expect(headerValues(preserved, in: derivedFields) == ["kept"])
        #expect(headerValues(added, in: derivedFields) == ["kept-in-request-layer"])
        #expect(headerValues(discarded, in: derivedFields).isEmpty)
        #expect(headerValues(requestOverride, in: derivedFields).isEmpty)
    }

    @Test
    func inputRequestCapturesFixedEndpointHeaders() async throws {
        let transport = HeaderRecordingTransport()
        let fixed = try makeHeaderName("X-Fixed-Endpoint")
        let routeURL = try makeHeaderURL("https://example.com/input-fixed-headers")
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "route-witness") { _ in routeURL },
            response: .data,
        )
        .headers(makeHeaderFields((fixed, "fixed-value")))
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint, input: "bound-input"))

        let requests = await transport.receivedRequests()
        let fields = try #require(requests.first?.headerFields)
        #expect(headerValues(fixed, in: fields) == ["fixed-value"])
    }

    @Test
    func endpointWithoutHeaderConfigurationSendsEmptyHeaderFields() async throws {
        let transport = HeaderRecordingTransport()
        let routeURL = try makeHeaderURL("https://example.com/no-headers")
        let builderCalls = Mutex(0)
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(routeURL),
            response: .data,
        )
        .headers(makeHeaderBuilder(
            onBuild: { builderCalls.withLock { $0 += 1 } },
            fields: HTTPFields(),
        ))
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint))

        let requests = await transport.receivedRequests()
        let fields = try #require(requests.first?.headerFields)
        #expect(builderCalls.withLock { $0 } == 0)
        #expect(fields.isEmpty)
    }

    @Test
    func noInputRequestDoesNotInvokeInputDerivedHeaderBuilder() async throws {
        let transport = HeaderRecordingTransport()
        let builderCalls = Mutex(0)
        let routeURL = try makeHeaderURL("https://example.com/no-input-builder")
        let inputDerived = try makeHeaderName("X-Input-Only")
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(routeURL),
            response: .data,
        )
        .headers(makeHeaderBuilder(
            onBuild: { builderCalls.withLock { $0 += 1 } },
            fields: makeHeaderFields((inputDerived, "unavailable")),
        ))
        let client = try NetworkClient(transport: transport)
        let request: Request<Data> = Request(endpoint: endpoint)

        _ = try await client.send(request)

        let requests = await transport.receivedRequests()
        let fields = try #require(requests.first?.headerFields)
        #expect(builderCalls.withLock { $0 } == 0)
        #expect(fields.isEmpty)
    }

    @Test
    func configurationCopiesPreserveHeadersAndDefaultHeaderModifierReplacesLayer() throws {
        let originalName = try makeHeaderName("X-Original")
        let repeated = try makeHeaderName("X-Default-Repeated")
        let replacementName = try makeHeaderName("X-Replacement")
        let original = makeHeaderFields(
            (originalName, "original"),
            (repeated, "first"),
            (repeated, "second"),
        )
        let configuration = NetworkClient.Configuration()
            .withDefaultHeaders(original)
            .withDefaultQueryItems([URLQueryItem(name: "key", value: "value")])
            .withURLQueryEncoderConfiguration(.init(boolStrategy: .numeric))
            .withRequestIDGenerator(UUIDRequestIDGenerator())

        #expect(headerValues(originalName, in: configuration.defaultHeaders) == ["original"])
        #expect(headerValues(repeated, in: configuration.defaultHeaders) == ["first", "second"])

        let replacement = configuration.withDefaultHeaders(makeHeaderFields(
            (replacementName, "replacement"),
        ))
        #expect(headerValues(originalName, in: replacement.defaultHeaders).isEmpty)
        #expect(headerValues(repeated, in: replacement.defaultHeaders).isEmpty)
        #expect(headerValues(replacementName, in: replacement.defaultHeaders) == ["replacement"])
        #expect(replacement.defaultQueryItems == [URLQueryItem(name: "key", value: "value")])
    }
}

private func makeHeaderName(_ value: String) throws -> HTTPField.Name {
    try #require(HTTPField.Name(value))
}

private func makeHeaderFields(_ entries: (HTTPField.Name, String)...) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in entries {
        fields.append(HTTPField(name: name, value: value))
    }
    return fields
}

private func makeHeaderBuilder<Input: Sendable>(
    onBuild: @escaping @Sendable () -> Void,
    fields: HTTPFields,
) -> @Sendable (Input) -> HTTPFields {
    { _ in
        onBuild()
        return fields
    }
}

private func headerValues(_ name: HTTPField.Name, in fields: HTTPFields) -> [String] {
    fields.filter { $0.name == name }.map(\.value)
}

private func makeHeaderURL(_ value: String) throws -> URL {
    try #require(URL(string: value))
}

private actor HeaderRecordingTransport: NetworkTransport {
    private var requests: [HTTPRequest] = []

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request.httpRequest)
        return (Data(), HTTPResponse(status: .init(code: 200)))
    }

    func receivedRequests() -> [HTTPRequest] {
        requests
    }
}
