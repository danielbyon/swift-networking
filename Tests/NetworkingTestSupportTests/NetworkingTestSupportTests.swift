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

@Test("HTTP retries sleep for the resolved server delay before the next attempt")
func httpRetrySleepsForResolvedServerDelay() async throws {
    let sleeper = RetryTimingSleepRecorder()
    let timing = RetryTimingTestSupport.dependencies(
        sleep: { delay in try await sleeper.sleep(for: delay) },
        now: { Date(timeIntervalSince1970: 0) },
        randomUnit: { 0.5 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    retryConfiguration.backoffStrategy = .constant(.seconds(10), jitter: .full)
    let transport = ScriptedRetryTimingTransport([
        .response(Data(), retryTimingResponse(status: 503, retryAfter: "8")),
        .response(Data([0x2a]), retryTimingResponse(status: 200)),
    ])
    let client = try NetworkClient(
        transport: transport,
        configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        retryTimingDependencies: timing,
    )

    let response = try await client.send(makeRetryTimingRequest())

    #expect(await sleeper.recordedDelays() == [.seconds(8)])
    #expect(await transport.executionCount() == 2)
    #expect(response.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
}

@Test("Transport retries use local jitter and never require a real sleep")
func transportRetryUsesLocalJitter() async throws {
    let sleeper = RetryTimingSleepRecorder()
    let timing = RetryTimingTestSupport.dependencies(
        sleep: { delay in try await sleeper.sleep(for: delay) },
        now: { Date(timeIntervalSince1970: 0) },
        randomUnit: { 0.5 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    retryConfiguration.backoffStrategy = .constant(.seconds(3), jitter: .full)
    let transport = ScriptedRetryTimingTransport([
        .failure(URLError(.timedOut)),
        .response(Data([0x2a]), retryTimingResponse(status: 200)),
    ])
    let client = try NetworkClient(
        transport: transport,
        configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        retryTimingDependencies: timing,
    )

    let response = try await client.send(makeRetryTimingRequest())

    #expect(await sleeper.recordedDelays() == [.seconds(1.5)])
    #expect(await transport.executionCount() == 2)
    #expect(response.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
}

@Test("Zero-delay retries start the next attempt without invoking the sleeper")
func zeroDelayRetrySkipsSleeper() async throws {
    let sleeper = RetryTimingSleepRecorder()
    let timing = RetryTimingTestSupport.dependencies(
        sleep: { delay in try await sleeper.sleep(for: delay) },
        now: { Date(timeIntervalSince1970: 0) },
        randomUnit: { 0.5 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    let transport = ScriptedRetryTimingTransport([
        .response(Data(), retryTimingResponse(status: 503)),
        .response(Data([0x2a]), retryTimingResponse(status: 200)),
    ])
    let client = try NetworkClient(
        transport: transport,
        configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        retryTimingDependencies: timing,
    )

    let response = try await client.send(makeRetryTimingRequest())

    #expect(await sleeper.recordedDelays().isEmpty)
    #expect(await transport.executionCount() == 2)
    #expect(response.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
}

@Test("Cancellation during retry sleep prevents the next transport attempt")
func cancellationDuringRetrySleepPreventsNextAttempt() async throws {
    let sleeper = RetryTimingSleepRecorder(blocksUntilCancelled: true)
    let timing = RetryTimingTestSupport.dependencies(
        sleep: { delay in try await sleeper.sleep(for: delay) },
        now: { Date(timeIntervalSince1970: 0) },
        randomUnit: { 0.5 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    retryConfiguration.backoffStrategy = .constant(.seconds(5))
    let transport = ScriptedRetryTimingTransport([
        .response(Data(), retryTimingResponse(status: 503)),
        .response(Data([0x2a]), retryTimingResponse(status: 200)),
    ])
    let client = try NetworkClient(
        transport: transport,
        configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        retryTimingDependencies: timing,
    )
    let networkTask = try client.task(for: makeRetryTimingRequest())
    let waiter = Task { try await networkTask.value }

    await sleeper.waitUntilSleeping()
    networkTask.cancel()

    do {
        _ = try await waiter.value
        Issue.record("Expected retry sleep cancellation to stop the logical execution")
    } catch is CancellationError {}

    #expect(await sleeper.recordedDelays() == [.seconds(5)])
    #expect(await transport.executionCount() == 1)
}

private func makeRetryTimingRequest() throws -> Request<Data> {
    let url = try #require(URL(string: "https://example.com/retry-timing"))
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func retryTimingResponse(status: Int, retryAfter: String? = nil) -> HTTPResponse {
    var fields = HTTPFields()
    if let retryAfter {
        fields[fields: .retryAfter] = [HTTPField(name: .retryAfter, value: retryAfter)]
    }
    return HTTPResponse(status: .init(code: status), headerFields: fields)
}

private actor ScriptedRetryTimingTransport: NetworkTransport {
    enum Step: Sendable {
        case response(Data, HTTPResponse)
        case failure(URLError)
    }

    private var steps: [Step]
    private var requests: [TransportRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw URLError(.badServerResponse)
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        requests.append(request)
        guard !steps.isEmpty else {
            return .failure(
                error: URLError(.badServerResponse),
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        let result: NetworkTransportResult =
            switch steps.removeFirst() {
            case let .response(data, response):
                .success(data: data, response: response, rawTaskMetrics: nil)
            case let .failure(error):
                .failure(error: error, rawTaskMetrics: nil, didStartTask: true)
            }
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        return result
    }

    func executionCount() -> Int {
        requests.count
    }
}

private actor RetryTimingSleepRecorder {
    private let blocksUntilCancelled: Bool
    private var delays: [Duration] = []
    private var sleepingWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Void, any Error>?
    private var isSleeping = false

    init(blocksUntilCancelled: Bool = false) {
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func sleep(for delay: Duration) async throws {
        delays.append(delay)
        guard blocksUntilCancelled else {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepContinuation = continuation
                isSleeping = true
                let waiters = sleepingWaiters
                sleepingWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
    }

    func waitUntilSleeping() async {
        guard !isSleeping else {
            return
        }

        await withCheckedContinuation { sleepingWaiters.append($0) }
    }

    func recordedDelays() -> [Duration] {
        delays
    }

    private func cancelSleep() {
        guard let sleepContinuation else {
            return
        }

        self.sleepContinuation = nil
        sleepContinuation.resume(throwing: CancellationError())
    }
}
