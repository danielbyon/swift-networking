//
//  RequestIDGeneratorsTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Testing
@testable import NetworkingTestSupport

@Test("The static generator returns its configured identity for every execution")
func staticGeneratorReturnsConfiguredIdentity() {
    let requestID = RequestID(rawValue: UUID())
    let generator = StaticRequestIDGenerator(requestID: requestID)

    #expect(generator.generateRequestID() == requestID)
    #expect(generator.generateRequestID() == requestID)
}

@Test("The sequence generator allocates configured identities in order")
func sequenceGeneratorAllocatesIdentitiesInOrder() {
    let identities = (0 ..< 3).map { _ in RequestID(rawValue: UUID()) }
    let generator = SequenceRequestIDGenerator(requestIDs: identities)

    #expect(generator.remainingCount == 3)
    #expect(generator.isExhausted == false)
    #expect(generator.generateRequestID() == identities[0])
    #expect(generator.generateRequestID() == identities[1])
    #expect(generator.remainingCount == 1)
    #expect(generator.generateRequestID() == identities[2])
    #expect(generator.isExhausted)
    #expect(generator.remainingCount == 0)
}

@Test("Concurrent sequence allocation returns every configured identity exactly once")
func sequenceGeneratorSerializesConcurrentAllocation() async {
    let identities = (0 ..< 128).map { _ in RequestID(rawValue: UUID()) }
    let generator = SequenceRequestIDGenerator(requestIDs: identities)

    let allocated = await withTaskGroup(of: RequestID.self) { group in
        for _ in identities {
            group.addTask { generator.generateRequestID() }
        }

        var values: [RequestID] = []
        for await value in group {
            values.append(value)
        }
        return values
    }

    #expect(allocated.count == identities.count)
    #expect(Set(allocated) == Set(identities))
    #expect(generator.isExhausted)
}

@Test("Configured identities reach logical executions and grouped recording")
func configuredIdentitiesReachLogicalExecutions() async throws {
    let url = try #require(URL(string: "https://mock.example/identities"))
    let identities = [RequestID(rawValue: UUID()), RequestID(rawValue: UUID())]
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        consumption: .always,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let configuration = NetworkClient.Configuration()
        .withRequestIDGenerator(SequenceRequestIDGenerator(requestIDs: identities))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let first = try await client.send(identityRequest(url: url))
    let second = try await client.send(identityRequest(url: url))

    #expect(first.requestID == identities[0])
    #expect(second.requestID == identities[1])
    let recorded = await transport.recordedRequests()
    #expect(recorded.map(\.requestID) == identities)
    let groups = await transport.recordedRequestsByRequestID()
    #expect(groups.map(\.requestID) == identities)
}

private func identityRequest(url: URL) -> Request<Data> {
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}
