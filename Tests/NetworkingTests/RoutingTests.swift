//
//  RoutingTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct RoutingTests {
    @Test("Absolute route fragments are removed before transport")
    func absoluteRouteFragmentsAreRemovedBeforeTransport() async throws {
        let transport = RoutingRecordingTransport()
        let baseURL = try #require(URL(string: "https://base.example.com/root"))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL),
        )
        let url = try #require(URL(string: "https://example.com/items?key=a%2Fb#section"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )

        _ = try await client.send(Request(endpoint: endpoint))

        #expect(await transport.recordedURLs() == ["https://example.com/items?key=a%2Fb"])
    }

    @Test("Unsupported absolute route schemes fail before transport with the execution ID")
    func unsupportedAbsoluteRouteSchemeFailsBeforeTransportWithRequestID() async throws {
        let transport = RoutingRecordingTransport()
        let requestID = RequestID(rawValue: UUID())
        let generator = RoutingCountingRequestIDGenerator(requestID: requestID)
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(generator),
        )
        let url = try #require(URL(string: "ftp://example.com/items"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )

        let task = client.task(for: Request(endpoint: endpoint))
        #expect(task.requestID == requestID)

        do {
            _ = try await task.value
            Issue.record("Expected the unsupported URL scheme to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.requestID == task.requestID)
            #expect(error.reason == .unsupportedURLScheme("ftp"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(generator.callCount == 1)
        #expect(await transport.executionCount() == 0)
    }

    @Test("Absolute routes without schemes fail before transport")
    func absoluteRouteWithoutSchemeFailsBeforeTransport() async throws {
        let transport = RoutingRecordingTransport()
        let requestID = RequestID(rawValue: UUID())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(RoutingFixedRequestIDGenerator(requestID: requestID)),
        )
        let url = try #require(URL(string: "relative/path"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        let task = client.task(for: Request(endpoint: endpoint))

        do {
            _ = try await task.value
            Issue.record("Expected the missing URL scheme to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.requestID == task.requestID)
            #expect(error.reason == .missingURLScheme)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.executionCount() == 0)
    }

    @Test("Relative routes without a base URL fail before transport with the execution ID")
    func relativeRouteWithoutBaseURLFailsBeforeTransportWithRequestID() async throws {
        let transport = RoutingRecordingTransport()
        let requestID = RequestID(rawValue: UUID())
        let generator = RoutingCountingRequestIDGenerator(requestID: requestID)
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(generator),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "witness") { input in ["items", input] },
            response: .data,
        )
        let request = Request(endpoint: endpoint, input: "42")
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected a relative route without a base URL to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.requestID == task.requestID)
            #expect(error.reason == .relativeRouteRequiresBaseURL)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(generator.callCount == 1)
        #expect(await transport.executionCount() == 0)
    }

    @Test("Relative route components stay encoded within the configured base path")
    func relativeRouteComponentsStayWithinBasePath() async throws {
        let components = [
            "users",
            "a/b",
            "?query",
            "#fragment",
            "space and snowman ☃",
            ".",
            "..",
            "v1.2.0",
            "file.json",
            ".well-known",
            "a..b",
        ]
        let expectedURL = "https://example.com/api/v1/users/a%2Fb/%3Fquery/%23fragment/space%20and%20snowman%20%E2%98%83/%2E/%2E%2E/v1.2.0/file.json/.well-known/a..b"

        for baseURLString in ["https://example.com/api/v1", "https://example.com/api/v1/"] {
            let transport = RoutingRecordingTransport()
            let baseURL = try #require(URL(string: baseURLString))
            let client = try NetworkClient(
                transport: transport,
                configuration: .init(baseURL: baseURL),
            )
            let endpoint = Endpoint<Int, Never, Data>.data(
                method: .get,
                route: .relative(forInput: 0) { _ in components },
                response: .data,
            )

            _ = try await client.send(Request(endpoint: endpoint, input: 1))

            #expect(await transport.recordedURLs() == [expectedURL])
            #expect(await transport.recordedURLs().first?.hasPrefix("https://example.com/api/v1/") == true)
        }
    }

    @Test("An empty relative component remains one empty path segment")
    func emptyRelativeComponentRemainsOnePathSegment() async throws {
        let transport = RoutingRecordingTransport()
        let baseURL = try #require(URL(string: "https://example.com/api/v1/"))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL),
        )
        let endpoint = Endpoint<Bool, Never, Data>.data(
            method: .get,
            route: .relative(forInput: true) { _ in ["", "tail"] },
            response: .data,
        )

        _ = try await client.send(Request(endpoint: endpoint, input: false))

        #expect(await transport.recordedURLs() == ["https://example.com/api/v1//tail"])
    }

    @Test("Relative routing preserves encoded base path and authority data")
    func relativeRoutingPreservesEncodedBasePathAndAuthority() async throws {
        let transport = RoutingRecordingTransport()
        let baseURL = try #require(URL(string: "https://example.com:8443/api/%2Froot/"))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL),
        )
        let endpoint = Endpoint<Int, Never, Data>.data(
            method: .get,
            route: .relative(forInput: 0) { _ in ["items"] },
            response: .data,
        )

        _ = try await client.send(Request(endpoint: endpoint, input: 1))

        #expect(await transport.recordedURLs() == ["https://example.com:8443/api/%2Froot/items"])
    }

    @Test("Relative route builders resolve once when Request is initialized")
    func relativeRouteBuilderResolvesOnceAtRequestInitialization() async throws {
        let builderCalls = Mutex(0)
        let transport = RoutingRecordingTransport()
        let baseURL = try #require(URL(string: "https://example.com/api/"))
        let requestID = RequestID(rawValue: UUID())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL).withRequestIDGenerator(
                RoutingFixedRequestIDGenerator(requestID: requestID),
            ),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "witness") { input in
                builderCalls.withLock { $0 += 1 }
                return ["items", input]
            },
            response: .data,
        )
        let request = Request(endpoint: endpoint, input: "42")

        #expect(builderCalls.withLock { $0 } == 1)
        let first = try await client.send(request)
        let second = try await client.send(request)

        #expect(builderCalls.withLock { $0 } == 1)
        #expect(first.requestID == requestID)
        #expect(second.requestID == requestID)
        #expect(await transport.recordedURLs() == [
            "https://example.com/api/items/42",
            "https://example.com/api/items/42",
        ])
    }

    @Test("Absolute route builders resolve once when Request is initialized")
    func absoluteRouteBuilderResolvesOnceAtRequestInitialization() async throws {
        let builderCalls = Mutex(0)
        let transport = RoutingRecordingTransport()
        let client = try NetworkClient(transport: transport)
        let routeURL = try #require(URL(string: "https://example.com/items/42"))
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "witness") { _ in
                builderCalls.withLock { $0 += 1 }
                return routeURL
            },
            response: .data,
        )
        let request = Request(endpoint: endpoint, input: "42")

        #expect(builderCalls.withLock { $0 } == 1)
        _ = try await client.send(request)
        _ = try await client.send(request)

        #expect(builderCalls.withLock { $0 } == 1)
        #expect(await transport.recordedURLs() == [
            "https://example.com/items/42",
            "https://example.com/items/42",
        ])
    }

    @Test("Base URL validation aggregates only scheme query and fragment failures in order")
    func baseURLValidationAggregatesFailuresInContractOrder() throws {
        let transport = RoutingRecordingTransport()
        let baseURL = try #require(URL(string: "ftp://example.com/api?key=value#section"))
        let configuration = NetworkClient.Configuration(baseURL: baseURL)

        do {
            _ = try NetworkClient(transport: transport, configuration: configuration)
            Issue.record("Expected the invalid base URL to fail client initialization")
        } catch let error as NetworkClient.ConfigurationError {
            #expect(error.failures == [.baseURLScheme, .baseURLQuery, .baseURLFragment])
        }
    }

    @Test("Base URL validation rejects empty query and fragment markers")
    func baseURLValidationRejectsEmptyQueryAndFragmentMarkers() throws {
        let transport = RoutingRecordingTransport()
        let cases: [(String, NetworkClient.ConfigurationError.Failure)] = [
            ("https://example.com/api?", .baseURLQuery),
            ("https://example.com/api#", .baseURLFragment),
        ]

        for (urlString, expectedFailure) in cases {
            let baseURL = try #require(URL(string: urlString))
            let configuration = NetworkClient.Configuration(baseURL: baseURL)

            do {
                _ = try NetworkClient(transport: transport, configuration: configuration)
                Issue.record("Expected the empty URL component marker to fail validation")
            } catch let error as NetworkClient.ConfigurationError {
                #expect(error.failures == [expectedFailure])
            }
        }
    }

    @Test("A base URL without authority reaches route preflight instead of configuration validation")
    func baseURLWithoutAuthorityFailsOnlyDuringRoutePreflight() async throws {
        let transport = RoutingRecordingTransport()
        let requestID = RequestID(rawValue: UUID())
        let baseURL = try #require(URL(string: "https:/api/v1"))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init(baseURL: baseURL).withRequestIDGenerator(
                RoutingFixedRequestIDGenerator(requestID: requestID),
            ),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "witness") { input in [input] },
            response: .data,
        )
        let task = client.task(for: Request(endpoint: endpoint, input: "item"))

        do {
            _ = try await task.value
            Issue.record("Expected the unconstructable relative URL to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.requestID == task.requestID)
            #expect(error.reason == .urlCompositionFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.executionCount() == 0)
    }

    @Test("The baseURL convenience initializer constructs a client for a valid URL")
    func baseURLConvenienceInitializerAcceptsValidURL() throws {
        let baseURL = try #require(URL(string: "https://example.com/api/v1"))

        _ = try NetworkClient(baseURL: baseURL)
    }
}

private actor RoutingRecordingTransport: NetworkTransport {
    private var requests: [HTTPRequest] = []

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request.httpRequest)
        return (Data(), HTTPResponse(status: .init(code: 200)))
    }

    func recordedURLs() -> [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    func executionCount() -> Int {
        requests.count
    }
}

private struct RoutingFixedRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private final class RoutingCountingRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID
    private let calls = Mutex(0)

    init(requestID: RequestID) {
        self.requestID = requestID
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    func generateRequestID() -> RequestID {
        calls.withLock { $0 += 1 }
        return requestID
    }
}
