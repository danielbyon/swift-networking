//
//  NetworkTestDependenciesTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Testing
@testable import NetworkingTestSupport

@Test("Deterministic dependencies resolve jittered retry delays without wall-clock sleeping")
func deterministicDependenciesResolveJitteredRetryDelays() async throws {
    let url = try #require(URL(string: "https://mock.example/jitter"))
    let delays = DelayRecorder()
    let dependencies = NetworkTestDependencies(
        sleep: { delay in await delays.record(delay) },
        now: { Date(timeIntervalSince1970: 0) },
        randomUnit: { 0.25 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    retryConfiguration.backoffStrategy = .constant(.seconds(4), jitter: .full)
    let configuration = NetworkClient.Configuration()
        .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data(), response: dependenciesResponse(status: 503)),
        ),
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: dependenciesResponse(status: 200)),
        ),
    ])
    let client = try NetworkClient.testing(
        configuration: configuration,
        transport: transport,
        dependencies: dependencies,
    )

    let response = try await client.send(dependenciesRequest(url: url))

    #expect(await delays.recordedDelays() == [.seconds(1)])
    #expect(response.value == Data([0x2a]))
    #expect(response.attempts.map(\.attemptNumber) == [1, 2])
    #expect(response.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
}

@Test("Retry-After HTTP dates resolve against the injected wall clock")
func retryAfterHTTPDatesResolveAgainstInjectedWallClock() async throws {
    let url = try #require(URL(string: "https://mock.example/retry-after-date"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let delays = DelayRecorder()
    let dependencies = NetworkTestDependencies(
        sleep: { delay in await delays.record(delay) },
        now: { now },
        randomUnit: { 0 },
    )
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    let configuration = NetworkClient.Configuration()
        .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
    let retryAfter = httpDate(now.addingTimeInterval(45))
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(
                data: Data(),
                response: dependenciesResponse(status: 503, retryAfter: retryAfter),
            ),
        ),
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: dependenciesResponse(status: 200)),
        ),
    ])
    let client = try NetworkClient.testing(
        configuration: configuration,
        transport: transport,
        dependencies: dependencies,
    )

    let response = try await client.send(dependenciesRequest(url: url))

    #expect(await delays.recordedDelays() == [.seconds(45)])
    #expect(response.value == Data([0x2a]))
}

@Test("Lifecycle event timestamps use the injected wall clock")
func lifecycleEventTimestampsUseInjectedWallClock() async throws {
    let url = try #require(URL(string: "https://mock.example/timestamps"))
    let now = Date(timeIntervalSince1970: 1_700_000_123)
    let recorder = NetworkEventRecorder()
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: dependenciesResponse(status: 200)),
        ),
    ])
    let configuration = NetworkClient.Configuration().withEventObserver(recorder.observer)
    let client = try NetworkClient.testing(
        configuration: configuration,
        transport: transport,
        dependencies: .deterministic(now: now),
    )

    let response = try await client.send(dependenciesRequest(url: url))
    let terminal = try await recorder.waitForTerminalEvent(for: response.requestID)

    guard case let .requestCompleted(completed) = terminal else {
        Issue.record("Expected a completed terminal event, received \(terminal)")
        return
    }

    #expect(completed.timestamp == now)
    let recordedEvents = recorder.recordedEvents()
    #expect(recordedEvents.isEmpty == false)
    #expect(recordedEvents.allSatisfy { recordedTimestamp(of: $0) == now })
}

private actor DelayRecorder {
    private var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }

    func recordedDelays() -> [Duration] {
        delays
    }
}

private func dependenciesResponse(status: Int, retryAfter: String? = nil) -> HTTPResponse {
    var fields = HTTPFields()
    if let retryAfter {
        fields[fields: .retryAfter] = [HTTPField(name: .retryAfter, value: retryAfter)]
    }
    return HTTPResponse(status: .init(code: status), headerFields: fields)
}

private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
}

private func dependenciesRequest(url: URL) -> Request<Data> {
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func recordedTimestamp(of event: NetworkEvent) -> Date {
    switch event {
    case let .requestStarted(event):
        event.timestamp
    case let .attemptStarted(event):
        event.timestamp
    case let .responseReceived(event):
        event.timestamp
    case let .attemptFailed(event):
        event.timestamp
    case let .authenticationReplayScheduled(event):
        event.timestamp
    case let .retryScheduled(event):
        event.timestamp
    case let .redirectDecision(event):
        event.timestamp
    case let .requestCompleted(event):
        event.timestamp
    case let .requestFailed(event):
        event.timestamp
    case let .requestCancelled(event):
        event.timestamp
    }
}
