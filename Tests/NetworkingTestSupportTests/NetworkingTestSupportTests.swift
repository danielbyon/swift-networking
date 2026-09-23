//
//  NetworkingTestSupportTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Testing
@testable import NetworkingTestSupport

@Test("send returns the raw response bytes and HTTP response")
func sendReturnsRawDataResponse() async throws {
    let payload = Data([0x00, 0x7f, 0xff])
    let httpResponse = HTTPResponse(status: .init(code: 206))
    let transport = StubNetworkTransport(response: payload, httpResponse: httpResponse)
    let client = try NetworkClient(transport: transport)
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/raw"))),
        response: .data,
    )

    let response = try await client.send(Request(endpoint: endpoint))

    #expect(response.value == payload)
    #expect(response.httpResponse == httpResponse)
}

@Test("send preserves the endpoint method and absolute route")
func sendPreservesMethodAndAbsoluteRoute() async throws {
    let transport = StubNetworkTransport(
        response: Data(),
        httpResponse: HTTPResponse(status: .init(code: 200)),
    )
    let client = try NetworkClient(transport: transport)
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .post,
        route: .absolute(#require(URL(string: "https://example.com/submit"))),
        response: .data,
    )

    _ = try await client.send(Request(endpoint: endpoint))

    let requests = await transport.receivedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.method == .post)
    #expect(requests.first?.url?.absoluteString == "https://example.com/submit")
}

@Test("Request binds an input-derived absolute route")
func requestBindsInputDerivedRoute() async throws {
    let transport = StubNetworkTransport(
        response: Data([0x2a]),
        httpResponse: HTTPResponse(status: .init(code: 200)),
    )
    let client = try NetworkClient(transport: transport)
    let routePrefix = try #require(URL(string: "https://example.com/items/"))
    let endpoint = Endpoint<String, Never, Data>.data(
        method: .get,
        route: .absolute(forInput: "route-witness") { identifier in
            routePrefix.appendingPathComponent(identifier)
        },
        response: .data,
    )
    let request: Request<Data> = Request(endpoint: endpoint, input: "42")

    let response = try await client.send(request)

    let requests = await transport.receivedRequests()
    #expect(response.value == Data([0x2a]))
    #expect(requests.first?.url?.absoluteString == "https://example.com/items/42")
}

@Test("send propagates transport errors unchanged")
func sendPropagatesTransportError() async throws {
    let transport = StubNetworkTransport(error: .expectedFailure)
    let client = try NetworkClient(transport: transport)
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/failure"))),
        response: .data,
    )

    do {
        _ = try await client.send(Request(endpoint: endpoint))
        Issue.record("Expected the transport error to propagate")
    } catch let error as StubTransportError {
        #expect(error == .expectedFailure)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("sending the same Request performs independent transport executions")
func sendingSameRequestExecutesTransportTwice() async throws {
    let payload = Data([0x10, 0x20])
    let httpResponse = HTTPResponse(status: .init(code: 200))
    let transport = StubNetworkTransport(response: payload, httpResponse: httpResponse)
    let client = try NetworkClient(transport: transport)
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/reused"))),
        response: .data,
    )
    let request = Request(endpoint: endpoint)

    let first = try await client.send(request)
    let second = try await client.send(request)

    #expect(first.value == payload)
    #expect(second.value == payload)
    #expect(await transport.executionCount() == 2)
}
