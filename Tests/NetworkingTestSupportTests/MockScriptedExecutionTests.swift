//
//  MockScriptedExecutionTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking
@testable import NetworkingTestSupport

@Test("A rejected attempt start records no request and consumes no stub")
func rejectedAttemptStartRecordsNoRequest() async throws {
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let coordinator = NetworkProgressCoordinator()
    let reporter = coordinator.reporter(commitAttemptStart: { _, _ in false })
    let request = TransportRequest(
        httpRequest: HTTPRequest(method: .get, scheme: "https", authority: "mock.example", path: "/gated"),
        body: .none,
        requestID: RequestID(rawValue: UUID()),
        operation: .data,
        execution: .data(body: nil),
    )

    let result = await transport.executeWithMetrics(request, progress: reporter)

    guard case let .failure(error, rawTaskMetrics, didStartTask, normalizedMetrics) = result else {
        Issue.record("Expected a rejected attempt start to fail with cancellation")
        return
    }

    #expect(error is CancellationError)
    #expect(rawTaskMetrics == nil)
    #expect(didStartTask == false)
    #expect(normalizedMetrics == nil)
    #expect(await transport.recordedRequests().isEmpty)
    do {
        try await transport.verifyAllFiniteStubsConsumed()
        Issue.record("Expected the unconsumed stub to fail verification")
    } catch let error as NetworkTestSupportError {
        #expect(error.localizedDescription.contains("Finite mock stubs"))
    }
}

@Test("Scripted upload progress reaches the normal task progress sequence")
func scriptedUploadProgressReachesProgressSequence() async throws {
    let url = try #require(URL(string: "https://mock.example/upload-progress"))
    let latency = StubLatency()
    let payload = Data([0x01, 0x02, 0x03])
    let stub = try NetworkStub(
        matching: .method(.post),
        response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        latency: latency,
        progress: [
            .upload(bytesSent: 1, expectedBytesToSend: 3),
            .upload(bytesSent: 3, expectedBytesToSend: 3),
        ],
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let recorder = NetworkProgressRecorder()
    let task = client.task(for: uploadProgressRequest(url: url, payload: payload))
    recorder.startRecording(task.progress)

    await latency.waitUntilSuspended(at: 1)
    await latency.release(at: 1)
    await recorder.waitUntilRecorded { $0.bytesSent == 1 }
    await latency.waitUntilSuspended(at: 2)
    await latency.release(at: 2)
    await recorder.waitUntilRecorded { $0.bytesSent == 3 }
    await latency.waitUntilSuspended(at: 3)
    await latency.release(at: 3)

    let response = try await task.value
    await recorder.waitUntilFinished()
    let recorded = recorder.recordedProgress()

    #expect(response.value == Data([0x2a]))
    let uploadStates = recorded.filter { $0.bytesSent > 0 }
    #expect(uploadStates.map(\.bytesSent) == [1, 3, 3])
    #expect(uploadStates.allSatisfy { $0.attemptNumber == 1 })
    #expect(uploadStates.allSatisfy { $0.expectedBytesToSend == 3 })
    #expect(recorded.last?.isComplete == true)
    #expect(recorded.last?.bytesSent == 3)
    let recordedRequests = await transport.recordedRequests()
    #expect(recordedRequests.count == 1)
}

@Test("Scripted download progress reaches the normal task progress sequence")
func scriptedDownloadProgressReachesProgressSequence() async throws {
    let url = try #require(URL(string: "https://mock.example/download-progress"))
    let latency = StubLatency()
    let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .download(data: payload, response: HTTPResponse(status: .init(code: 200))),
        latency: latency,
        progress: [.download(bytesReceived: 2, expectedBytesToReceive: 5)],
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let recorder = NetworkProgressRecorder()
    let task = client.task(for: downloadProgressRequest(url: url))
    recorder.startRecording(task.progress)

    await latency.waitUntilSuspended(at: 1)
    await latency.release(at: 1)
    await recorder.waitUntilRecorded { $0.bytesReceived == 2 }
    await latency.waitUntilSuspended(at: 2)
    await latency.release(at: 2)

    let response = try await task.value
    await recorder.waitUntilFinished()
    let recorded = recorder.recordedProgress()

    #expect(try Data(contentsOf: response.value.url) == payload)
    #expect(recorded.contains { $0.bytesReceived == 2 && $0.expectedBytesToReceive == 5 })
    #expect(recorded.last?.isComplete == true)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Cancelling a suspended mock attempt surfaces cancellation and records the observation")
func cancellingSuspendedMockAttemptRecordsCancellation() async throws {
    let latency = StubLatency()
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        latency: latency,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let coordinator = NetworkProgressCoordinator()
    let request = TransportRequest(
        httpRequest: HTTPRequest(method: .get, scheme: "https", authority: "mock.example", path: "/cancellation"),
        body: .none,
        requestID: RequestID(rawValue: UUID()),
        operation: .data,
        execution: .data(body: nil),
    )
    let attempt = Task { await transport.executeWithMetrics(request, progress: coordinator.reporter) }

    await latency.waitUntilSuspended(at: 1)
    attempt.cancel()
    let result = await attempt.value

    guard case let .failure(error, rawTaskMetrics, didStartTask, _) = result else {
        Issue.record("Expected a cancelled mock attempt to fail with cancellation")
        return
    }

    #expect(error is CancellationError)
    #expect(rawTaskMetrics == nil)
    #expect(didStartTask)

    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
    #expect(recorded.first?.cancellationObserved == true)
    try await transport.verifyCancellationObserved()
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Stub-supplied normalized metrics reach successful attempt histories")
func suppliedMetricsReachSuccessfulAttemptHistories() async throws {
    let url = try #require(URL(string: "https://mock.example/metrics"))
    let metrics = NormalizedAttemptMetrics(
        duration: .seconds(1.5),
        redirectCount: 2,
        requestBodyBytesSent: 3,
        responseBodyBytesReceived: 7,
        networkProtocolName: "h2",
        isReusedConnection: true,
        resourceFetchType: .networkLoad,
    )
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([0x2a]), response: HTTPResponse(status: .init(code: 200))),
        metrics: metrics,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)

    let response = try await client.send(scriptedExecutionRequest(url: url))

    let attempt = try #require(response.attempts.first)
    #expect(response.attempts.count == 1)
    #expect(attempt.attemptNumber == 1)
    #expect(attempt.outcome == .acceptedResponse)
    #expect(attempt.normalizedMetrics == metrics)
    #expect(attempt.rawTaskMetrics == nil)
}

@Test("Each mock attempt supplies its own normalized metrics")
func eachMockAttemptSuppliesItsOwnMetrics() async throws {
    let url = try #require(URL(string: "https://mock.example/metrics-retry"))
    let firstMetrics = NormalizedAttemptMetrics(duration: .seconds(0.5), requestBodyBytesSent: 1)
    let secondMetrics = NormalizedAttemptMetrics(duration: .seconds(0.75), responseBodyBytesReceived: 2)
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data(), response: scriptedExecutionResponse(status: 503)),
            metrics: firstMetrics,
        ),
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: scriptedExecutionResponse(status: 200)),
            metrics: secondMetrics,
        ),
    ])
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    let configuration = NetworkClient.Configuration()
        .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
    let client = try NetworkClient.testing(
        configuration: configuration,
        transport: transport,
        dependencies: .deterministic(),
    )

    let response = try await client.send(scriptedExecutionRequest(url: url))

    #expect(response.attempts.map(\.normalizedMetrics) == [firstMetrics, secondMetrics])
    #expect(response.attempts.allSatisfy { $0.rawTaskMetrics == nil })
}

@Test("A retryable transport failure keeps its stub metrics and the retry keeps its own")
func retryableTransportFailureKeepsSuppliedMetrics() async throws {
    let url = try #require(URL(string: "https://mock.example/retryable-failure-metrics"))
    let failureMetrics = NormalizedAttemptMetrics(duration: .seconds(0.25), networkProtocolName: "h2")
    let successMetrics = NormalizedAttemptMetrics(duration: .seconds(0.5), responseBodyBytesReceived: 1)
    let transport = try MockNetworkTransport(stubs: [
        NetworkStub(
            matching: .method(.get),
            response: .failure(URLError(.timedOut)),
            metrics: failureMetrics,
        ),
        NetworkStub(
            matching: .method(.get),
            response: .httpResponse(data: Data([0x2a]), response: scriptedExecutionResponse(status: 200)),
            metrics: successMetrics,
        ),
    ])
    var retryConfiguration = RetryPolicy.Configuration()
    retryConfiguration.maximumRetries = 1
    let configuration = NetworkClient.Configuration()
        .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
    let client = try NetworkClient.testing(
        configuration: configuration,
        transport: transport,
        dependencies: .deterministic(),
    )

    let response = try await client.send(scriptedExecutionRequest(url: url))

    #expect(response.value == Data([0x2a]))
    #expect(response.attempts.map(\.attemptNumber) == [1, 2])
    #expect(response.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
    #expect(response.attempts.map(\.normalizedMetrics) == [failureMetrics, successMetrics])
    #expect(response.attempts.allSatisfy { $0.rawTaskMetrics == nil })
    #expect(await transport.recordedRequests().map(\.attemptNumber) == [1, 2])
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("A terminal transport failure records the stub metrics on its failed attempt")
func terminalTransportFailureRecordsSuppliedMetrics() async throws {
    let url = try #require(URL(string: "https://mock.example/terminal-failure-metrics"))
    let requestID = RequestID(rawValue: UUID())
    let metrics = NormalizedAttemptMetrics(
        duration: .seconds(0.4),
        requestBodyBytesSent: 12,
        networkProtocolName: "http/1.1",
    )
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .failure(URLError(.badServerResponse)),
        metrics: metrics,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let recorder = NetworkEventRecorder()
    let configuration = NetworkClient.Configuration()
        .withEventObserver(recorder.observer)
        .withRequestIDGenerator(StaticRequestIDGenerator(requestID: requestID))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    do {
        _ = try await client.send(scriptedExecutionRequest(url: url))
        Issue.record("Expected the terminal transport failure to fail the logical request")
    } catch let error as URLError {
        #expect(error.code == .badServerResponse)
    }

    let terminal = try await recorder.waitForTerminalEvent(for: requestID)
    guard case .requestFailed = terminal else {
        Issue.record("Expected a requestFailed terminal event")
        return
    }

    let failedAttempts = recorder.recordedEvents(for: requestID).compactMap { event -> AttemptFailedEvent? in
        guard case let .attemptFailed(failedAttempt) = event else {
            return nil
        }

        return failedAttempt
    }
    let failedAttempt = try #require(failedAttempts.first)
    #expect(failedAttempts.count == 1)
    #expect(failedAttempt.requestID == requestID)
    #expect(failedAttempt.attemptNumber == 1)
    #expect(failedAttempt.normalizedMetrics == metrics)
    #expect(failedAttempt.rawTaskMetrics == nil)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("A failed download attempt keeps the stub metrics without raw task metrics")
func failedDownloadAttemptKeepsSuppliedMetrics() async throws {
    let metrics = NormalizedAttemptMetrics(duration: .seconds(0.2), networkProtocolName: "h3")
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .failure(URLError(.networkConnectionLost)),
        metrics: metrics,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let coordinator = NetworkProgressCoordinator()
    let request = TransportRequest(
        httpRequest: HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "mock.example",
            path: "/failed-download-metrics",
        ),
        body: .none,
        requestID: RequestID(rawValue: UUID()),
        operation: .download,
        execution: .download(body: nil),
    )

    let result = await transport.executeDownloadWithMetrics(request, progress: coordinator.reporter)

    guard case let .failure(error, rawTaskMetrics, didStartTask, normalizedMetrics) = result else {
        Issue.record("Expected the failed download attempt to report a failure")
        return
    }

    #expect(error is URLError)
    #expect(rawTaskMetrics == nil)
    #expect(didStartTask)
    #expect(normalizedMetrics == metrics)
    #expect(await transport.recordedRequests().count == 1)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Repeated attempts on one stub suspend independently at each pause-point occurrence")
func repeatedAttemptsSuspendAtEachPausePointOccurrence() async throws {
    let latency = StubLatency()
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .httpResponse(data: Data([0x2a]), response: scriptedExecutionResponse(status: 200)),
        consumption: .finite(2),
        latency: latency,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let coordinator = NetworkProgressCoordinator()
    let request = TransportRequest(
        httpRequest: HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "mock.example",
            path: "/repeated-latency",
        ),
        body: .none,
        requestID: RequestID(rawValue: UUID()),
        operation: .data,
        execution: .data(body: nil),
    )

    let firstAttempt = Task { await transport.executeWithMetrics(request, progress: coordinator.reporter) }
    await latency.waitUntilSuspended(at: 1)
    #expect(await transport.recordedRequests().count == 1)
    await latency.release(at: 1)
    guard case .success = await firstAttempt.value else {
        Issue.record("Expected the first scripted attempt to deliver its response")
        return
    }

    let secondDelivered = Mutex(false)
    let secondAttempt = Task {
        let result = await transport.executeWithMetrics(request, progress: coordinator.reporter)
        secondDelivered.withLock { $0 = true }
        return result
    }
    await latency.waitUntilSuspended(at: 1, occurrence: 2)
    #expect(await transport.recordedRequests().count == 2)
    #expect(secondDelivered.withLock { $0 } == false)
    await latency.release(at: 1)
    guard case .success = await secondAttempt.value else {
        Issue.record("Expected the second scripted attempt to deliver its response")
        return
    }

    #expect(await transport.recordedRequests().map(\.attemptNumber) == [1, 1])
    try await transport.verifyAllFiniteStubsConsumed()
}

private func scriptedExecutionResponse(status: Int) -> HTTPResponse {
    HTTPResponse(status: .init(code: status))
}

private func scriptedExecutionRequest(url: URL) -> Request<Data> {
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func uploadProgressRequest(url: URL, payload: Data) -> Request<Data> {
    let endpoint = Endpoint<Never, Data, Data>.upload(
        method: .post,
        route: .absolute(url),
        body: .data(contentType: "application/octet-stream"),
        response: .data,
    )
    return Request(endpoint: endpoint, body: payload)
}

private func downloadProgressRequest(url: URL) -> Request<DownloadedFile> {
    let endpoint = Endpoint<Never, Never, DownloadedFile>.download(
        method: .get,
        route: .absolute(url),
    )
    return Request(endpoint: endpoint)
}
