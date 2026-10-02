//
//  NetworkRecorderTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking
@testable import NetworkingTestSupport

@Test("The event recorder preserves the observed lifecycle order")
func eventRecorderPreservesObservedOrder() async throws {
    let url = try #require(URL(string: "https://mock.example/event-order"))
    let recorder = NetworkEventRecorder()
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        ),
    ])
    let configuration = NetworkClient.Configuration().withEventObserver(recorder.observer)
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let response = try await client.send(recorderRequest(url: url))
    let terminal = try await recorder.waitForTerminalEvent(for: response.requestID)

    guard case .requestCompleted = terminal else {
        Issue.record("Expected a completed terminal event, received \(terminal)")
        return
    }

    let events = recorder.recordedEvents(for: response.requestID)
    #expect(events.map(eventLabel) == ["requestStarted", "attemptStarted", "responseReceived", "requestCompleted"])
    #expect(recorder.recordedEvents().map(eventLabel).contains("requestCompleted"))
}

@Test("A terminal waiter observes delivery that happens after it starts waiting")
func terminalWaiterObservesLaterDelivery() async throws {
    let url = try #require(URL(string: "https://mock.example/event-wait"))
    let requestID = RequestID(rawValue: UUID())
    let latency = StubLatency()
    let recorder = NetworkEventRecorder()
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
            latency: latency,
        ),
    ])
    let configuration = NetworkClient.Configuration()
        .withEventObserver(recorder.observer)
        .withRequestIDGenerator(StaticRequestIDGenerator(requestID: requestID))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)
    let waiter = Task { try await recorder.waitForTerminalEvent(for: requestID) }
    let task = client.task(for: recorderRequest(url: url))

    await latency.waitUntilSuspended(at: 1)
    #expect(recorder.recordedEvents(for: requestID).map(eventLabel).contains("requestCompleted") == false)
    await latency.release(at: 1)

    let terminal = try await waiter.value
    _ = try await task.value

    guard case .requestCompleted = terminal else {
        Issue.record("Expected a completed terminal event, received \(terminal)")
        return
    }

    #expect(recorder.recordedEvents(for: requestID).map(eventLabel).last == "requestCompleted")
}

@Test("A terminal waiter resolves immediately when the event already arrived")
func terminalWaiterResolvesImmediatelyAfterDelivery() async throws {
    let url = try #require(URL(string: "https://mock.example/event-replay"))
    let recorder = NetworkEventRecorder()
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        ),
    ])
    let configuration = NetworkClient.Configuration().withEventObserver(recorder.observer)
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let response = try await client.send(recorderRequest(url: url))
    let first = try await recorder.waitForTerminalEvent(for: response.requestID)
    let second = try await recorder.waitForTerminalEvent(for: response.requestID)

    #expect(eventLabel(first) == "requestCompleted")
    #expect(eventLabel(second) == "requestCompleted")
}

@Test("Cancelling a terminal waiter leaves later delivery available")
func cancellingTerminalWaiterKeepsDeliveryAvailable() async throws {
    let url = try #require(URL(string: "https://mock.example/event-cancellation"))
    let requestID = RequestID(rawValue: UUID())
    let recorder = NetworkEventRecorder()
    let waiter = Task { try await recorder.waitForTerminalEvent(for: requestID) }
    waiter.cancel()

    do {
        _ = try await waiter.value
        Issue.record("Expected the cancelled terminal waiter to throw CancellationError")
    } catch is CancellationError {}

    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        ),
    ])
    let configuration = NetworkClient.Configuration()
        .withEventObserver(recorder.observer)
        .withRequestIDGenerator(StaticRequestIDGenerator(requestID: requestID))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let task = client.task(for: recorderRequest(url: url))
    let terminal = try await recorder.waitForTerminalEvent(for: requestID)
    _ = try await task.value

    #expect(eventLabel(terminal) == "requestCompleted")
}

@Test("The progress recorder matches recorded and future scripted states")
func progressRecorderMatchesRecordedAndFutureStates() async throws {
    let url = try #require(URL(string: "https://mock.example/progress-recorder"))
    let latency = StubLatency()
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
            latency: latency,
            progress: [.download(bytesReceived: 2, expectedBytesToReceive: 4)],
        ),
    ])
    let client = try NetworkClient.testing(transport: transport)
    let recorder = NetworkProgressRecorder()
    let task = client.task(for: recorderRequest(url: url))
    recorder.startRecording(task.progress)

    await latency.waitUntilSuspended(at: 1)
    let futureWait = Task { await recorder.waitUntilRecorded { $0.bytesReceived == 2 } }
    await latency.release(at: 1)
    await futureWait.value
    await latency.waitUntilSuspended(at: 2)
    await latency.release(at: 2)

    _ = try await task.value
    await recorder.waitUntilFinished()
    let recorded = recorder.recordedProgress()
    #expect(recorded.contains { $0.bytesReceived == 2 && $0.expectedBytesToReceive == 4 })
    #expect(recorded.last?.isComplete == true)

    await recorder.waitUntilRecorded { $0.bytesReceived == 2 }
}

@Test("Cancellation observed before admission wins over a delivered terminal event")
func cancellationBeforeAdmissionWinsOverDeliveredTerminalEvent() async throws {
    let url = try #require(URL(string: "https://mock.example/event-cancellation-race"))
    let requestID = RequestID(rawValue: UUID())
    let recorder = NetworkEventRecorder()
    let gate = OneShotGate()

    let waiter = Task { () -> NetworkEvent in
        await gate.wait()
        return try await recorder.waitForTerminalEvent(for: requestID)
    }
    waiter.cancel()

    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        ),
    ])
    let configuration = NetworkClient.Configuration()
        .withEventObserver(recorder.observer)
        .withRequestIDGenerator(StaticRequestIDGenerator(requestID: requestID))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    _ = try await client.send(recorderRequest(url: url))
    _ = try await recorder.waitForTerminalEvent(for: requestID)
    #expect(recorder.recordedEvents(for: requestID).map(eventLabel).contains("requestCompleted"))

    await gate.open()

    do {
        _ = try await waiter.value
        Issue.record("Expected the cancelled waiter to throw CancellationError")
    } catch is CancellationError {
        // Expected: the cancellation is observed before the waiter is admitted.
    } catch {
        Issue.record("Expected CancellationError, received \(error)")
    }
}

@Test("Progress recording subscribes before startRecording returns")
func progressRecordingSubscribesBeforeReturning() async {
    let coordinator = NetworkProgressCoordinator()
    let recorder = NetworkProgressRecorder()

    recorder.startRecording(coordinator.progress)
    #expect(coordinator.subscriberCount == 1)

    coordinator.updateDownload(bytesReceived: 2, expectedBytesToReceive: 4)
    coordinator.finish(successfully: false)

    await recorder.waitUntilFinished()
    #expect(recorder.recordedProgress().contains { $0.bytesReceived == 2 && $0.expectedBytesToReceive == 4 })
}

/// A one-shot gate that ignores cancellation, keeping a waiting task suspended until the test
/// opens it so tests can order cancellation against event delivery.
private actor OneShotGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard isOpen == false else {
            return
        }

        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private func recorderRequest(url: URL) -> Request<Data> {
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func eventLabel(_ event: NetworkEvent) -> String {
    switch event {
    case .requestStarted:
        "requestStarted"
    case .attemptStarted:
        "attemptStarted"
    case .responseReceived:
        "responseReceived"
    case .attemptFailed:
        "attemptFailed"
    case .authenticationReplayScheduled:
        "authenticationReplayScheduled"
    case .retryScheduled:
        "retryScheduled"
    case .redirectDecision:
        "redirectDecision"
    case .requestCompleted:
        "requestCompleted"
    case .requestFailed:
        "requestFailed"
    case .requestCancelled:
        "requestCancelled"
    }
}
