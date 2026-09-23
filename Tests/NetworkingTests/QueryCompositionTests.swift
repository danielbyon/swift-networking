//
//  QueryCompositionTests.swift
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
struct QueryCompositionTests {
    @Test
    func relativeQueryLayersUsePrecedence() async throws {
        let transport = QueryRecordingTransport()
        let builderCalls = Mutex(0)
        let baseURL = try makeURL("https://example.com/api/")
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL)
                .withDefaultQueryItems([
                    URLQueryItem(name: "shared", value: "client"),
                    URLQueryItem(name: "client", value: "one"),
                ]),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "witness") { _ in ["items"] },
            response: .data,
            query: .items { _ in
                builderCalls.withLock { $0 += 1 }
                return [
                    URLQueryItem(name: "shared", value: "endpoint-1"),
                    URLQueryItem(name: "shared", value: "endpoint-2"),
                    URLQueryItem(name: "endpoint", value: "value"),
                ]
            },
        )
        let request = Request(endpoint: endpoint, input: "ignored").queryItems([
            URLQueryItem(name: "shared", value: "request-1"),
            URLQueryItem(name: "shared", value: "request-2"),
            URLQueryItem(name: "request", value: "value"),
        ])

        _ = try await client.send(request)
        _ = try await client.send(request)

        #expect(builderCalls.withLock { $0 } == 1)
        #expect(await transport.executionCount() == 2)
        let recordedURLs = await transport.recordedURLs()
        assertSnapshot(of: recordedURLs, as: .json)
    }

    @Test
    func absoluteQueryCollisionUsesSemanticKeys() async throws {
        let transport = QueryRecordingTransport()
        let routeURL = try makeURL("https://example.com/items?keep=a%2Fb&other=first&a%2Fb=old&other=second#fragment")
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withDefaultQueryItems([URLQueryItem(name: "client", value: "omitted")]),
        )
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(routeURL),
            response: .data,
            query: .items([
                URLQueryItem(name: "a/b", value: "new"),
                URLQueryItem(name: "endpoint", value: "value"),
            ]),
        )
        let request = Request(endpoint: endpoint).queryItems([
            URLQueryItem(name: "request", value: "value"),
        ])

        _ = try await client.send(request)

        let recordedURLs = await transport.recordedURLs()
        assertSnapshot(of: recordedURLs, as: .json)
    }

    @Test
    func codableQuerySelectorIsCapturedOnce() async throws {
        let transport = QueryRecordingTransport()
        let firstID = try RequestID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let selectorCalls = Mutex(0)
        let baseURL = try makeURL("https://example.com/")
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL)
                .withDefaultQueryItems([URLQueryItem(name: "enabled", value: "client")])
                .withURLQueryEncoderConfiguration(.init(boolStrategy: .literal))
                .withRequestIDGenerator(QueryFixedRequestIDGenerator(requestID: firstID)),
        )
        let endpoint = Endpoint<QueryInput, Never, Data>.data(
            method: .get,
            route: .relative(forInput: QueryInput(id: "witness")) { input in ["items", input.id] },
            response: .data,
            query: .codable(
                configuration: .init(arrayStrategy: .brackets, boolStrategy: .numeric),
            ) { input in
                selectorCalls.withLock { $0 += 1 }
                return QueryValues(
                    enabled: input.enabled,
                    tags: [input.id, "second"],
                )
            },
        )
        let request = Request(endpoint: endpoint, input: QueryInput(id: "42", enabled: true))
            .queryItems([URLQueryItem(name: "request", value: "value")])

        let first = try await client.send(request)
        let second = try await client.send(request)

        #expect(selectorCalls.withLock { $0 } == 1)
        #expect(first.requestID == firstID)
        #expect(second.requestID == firstID)
        #expect(await transport.executionCount() == 2)
        let recordedURLs = await transport.recordedURLs()
        assertSnapshot(of: recordedURLs, as: .json)
    }

    @Test
    func noInputQueryValuesAreFixed() async throws {
        let transport = QueryRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let itemsURL = try makeURL("https://example.com/items")
        let codableURL = try makeURL("https://example.com/codable")
        let itemsEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(itemsURL),
            response: .data,
            query: .items([
                URLQueryItem(name: "fixed", value: "item"),
                URLQueryItem(name: "repeat", value: "one"),
                URLQueryItem(name: "repeat", value: "two"),
            ]),
        )
        let codableEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(codableURL),
            response: .data,
            query: .codable(
                NoInputQuery(value: "fixed"),
                configuration: .init(boolStrategy: .numeric),
            ),
        )
        _ = try await client.send(Request(endpoint: itemsEndpoint).queryItems([
            URLQueryItem(name: "request", value: "item"),
        ]))
        _ = try await client.send(Request(endpoint: codableEndpoint).queryItems([
            URLQueryItem(name: "manual", value: "one"),
        ]))

        let recordedURLs = await transport.recordedURLs()
        assertSnapshot(of: recordedURLs, as: .json)
    }

    @Test
    func neverInputClosuresAreIgnored() async throws {
        let transport = QueryRecordingTransport()
        let itemBuilderCalls = Mutex(0)
        let codableSelectorCalls = Mutex(0)
        let client = try NetworkClient(transport: transport)
        let itemsURL = try makeURL("https://example.com/ignored-items")
        let codableURL = try makeURL("https://example.com/ignored-codable")
        let itemsEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(itemsURL),
            response: .data,
            query: makeInputItems(for: Never.self) {
                itemBuilderCalls.withLock { $0 += 1 }
                return [URLQueryItem(name: "mustNotAppear", value: "item")]
            },
        )
        let codableEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(codableURL),
            response: .data,
            query: makeInputCodable(for: Never.self) {
                codableSelectorCalls.withLock { $0 += 1 }
                return NoInputQuery(value: "mustNotAppear")
            },
        )

        _ = try await client.send(Request(endpoint: itemsEndpoint))
        _ = try await client.send(Request(endpoint: codableEndpoint))

        #expect(itemBuilderCalls.withLock { $0 } == 0)
        #expect(codableSelectorCalls.withLock { $0 } == 0)
        let recordedURLs = await transport.recordedURLs()
        assertSnapshot(of: recordedURLs, as: .json)
    }

    @Test
    func configurationModifiersPreserveQueryConfiguration() throws {
        let defaults = [
            URLQueryItem(name: "client", value: "one"),
            URLQueryItem(name: "client", value: "two"),
        ]
        let baseURL = try makeURL("https://example.com/")
        let configuration = NetworkClient.Configuration(baseURL: baseURL)
            .withDefaultQueryItems(defaults)
            .withURLQueryEncoderConfiguration(.init(
                arrayStrategy: .brackets,
                boolStrategy: .numeric,
            ))
            .withRequestIDGenerator(QueryFixedRequestIDGenerator(requestID: RequestID(rawValue: UUID())))

        #expect(configuration.baseURL == baseURL)
        #expect(configuration.defaultQueryItems.map(\.name) == ["client", "client"])
        switch configuration.urlQueryEncoderConfiguration.arrayStrategy {
        case .brackets:
            break
        case .none:
            Issue.record("Expected bracket array strategy to survive derived copies")
        case .repeatedKey:
            Issue.record("Expected bracket array strategy to survive derived copies")
        }
        switch configuration.urlQueryEncoderConfiguration.boolStrategy {
        case .numeric:
            break
        case .none:
            Issue.record("Expected numeric Boolean strategy to survive derived copies")
        case .literal:
            Issue.record("Expected numeric Boolean strategy to survive derived copies")
        }
    }

    @Test
    func codableQueryFailureIsPretransport() async throws {
        let transport = QueryRecordingTransport()
        let requestID = try RequestID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withRequestIDGenerator(QueryFixedRequestIDGenerator(requestID: requestID)),
        )
        let itemsURL = try makeURL("https://example.com/items")
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(itemsURL),
            response: .data,
            query: .codable(NestedQuery(child: NestedChild(value: "value"))),
        )
        let task = client.task(for: Request(endpoint: endpoint))

        do {
            _ = try await task.value
            Issue.record("Expected nested query encoding to fail before transport")
        } catch let error as RequestConstructionError {
            #expect(error.requestID == requestID)
            #expect(error.reason == .urlQueryEncoding(.nestedKeyedContainer(codingPath: ["child"])))
        } catch {
            Issue.record("Unexpected query construction error: \(error)")
        }

        #expect(await transport.executionCount() == 0)
    }
}

private func makeURL(_ string: String) throws -> URL {
    try #require(URL(string: string))
}

private struct QueryInput: Sendable {
    let id: String
    var enabled = false
}

private func makeInputItems<Input: Sendable>(
    for _: Input.Type,
    _ build: @escaping @Sendable () -> [URLQueryItem],
) -> QueryEncoding<Input> {
    .items { _ in build() }
}

private func makeInputCodable<Input: Sendable>(
    for _: Input.Type,
    configuration: URLQueryEncoder.Configuration = .init(),
    _ select: @escaping @Sendable () -> some Encodable & Sendable,
) -> QueryEncoding<Input> {
    .codable(configuration: configuration) { _ in select() }
}

private struct QueryValues: Encodable, Sendable {
    let enabled: Bool
    let tags: [String]
}

private struct NoInputQuery: Encodable, Sendable {
    let value: String
    let enabled = true
}

private struct NestedQuery: Encodable, Sendable {
    let child: NestedChild
}

private struct NestedChild: Encodable, Sendable {
    let value: String
}

private actor QueryRecordingTransport: NetworkTransport {
    private var requests: [HTTPRequest] = []

    func execute(_ request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        return (Data(), HTTPResponse(status: .init(code: 200)))
    }

    func recordedURLs() -> [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    func executionCount() -> Int {
        requests.count
    }
}

private struct QueryFixedRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}
