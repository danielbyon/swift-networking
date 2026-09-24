//
//  RequestIDAndNetworkTaskTests.swift
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

@Suite(.serialized, .snapshots)
struct RequestIDAndNetworkTaskTests {
    @Test("RequestID snapshots its Codable JSON shape and round-trips")
    func requestIDCodableJSONSnapshotAndRoundTrips() throws {
        let requestID = try RequestID(
            rawValue: #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
        )

        assertSnapshot(of: requestID, as: .json)

        let encoded = try JSONEncoder().encode(requestID)
        let decoded = try JSONDecoder().decode(RequestID.self, from: encoded)
        #expect(decoded == requestID)
    }

    @Test("NetworkClient.Configuration defaults to UUIDRequestIDGenerator")
    func networkClientConfigurationDefaultsToUUIDRequestIDGenerator() {
        let configuration = NetworkClient.Configuration()

        #expect(configuration.requestIDGenerator is UUIDRequestIDGenerator)
    }

    @Test("NetworkClient exposes the throwing configuration initializer")
    func networkClientConfigurationInitializerIsPublic() throws {
        _ = NetworkClient()
        _ = try NetworkClient(configuration: .init())
    }

    @Test("task generates one injected RequestID before executing")
    func taskUsesInjectedRequestIDExactlyOnceBeforeExecution() async throws {
        let requestID = RequestID(rawValue: UUID())
        let generator = CountingRequestIDGenerator(requestID: requestID)
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x2a]),
                HTTPResponse(status: .init(code: 200)),
            ),
            gated: false,
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(generator),
        )

        let task = try client.task(for: makeRequest())
        #expect(task.requestID == requestID)

        let response = try await task.value

        #expect(response.requestID == requestID)
        #expect(generator.callCount == 1)
        #expect(await transport.executionCount == 1)
    }

    @Test("send owns one task and returns its RequestID")
    func sendUsesTaskIdentityAndPackageConfiguration() async throws {
        let requestID = RequestID(rawValue: UUID())
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x01, 0x02]),
                HTTPResponse(status: .init(code: 201)),
            ),
            gated: false,
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(FixedRequestIDGenerator(requestID: requestID)),
        )

        let response = try await client.send(makeRequest())

        #expect(response.requestID == requestID)
        #expect(response.value == Data([0x01, 0x02]))
        #expect(await transport.executionCount == 1)
    }

    @Test("shared task stores one success for concurrent and late awaiters")
    func sharedTaskStoresSuccessForConcurrentAndLateAwaiters() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x10, 0x20]),
                HTTPResponse(status: .init(code: 200)),
            ),
        )
        let decodeCount = Mutex(0)
        let client = try NetworkClient(transport: transport, configuration: .init())
        let request = try makeRequest(
            response: ResponseDecoding { data, _ in
                decodeCount.withLock { $0 += 1 }
                return data
            },
        )

        let task = client.task(for: request)
        await transport.waitForStart()

        let first = Task { try await task.value }
        let second = Task { try await task.value }
        await Task.yield()
        await Task.yield()

        await transport.releaseSuccess()

        let firstResponse = try await first.value
        let secondResponse = try await second.value
        let lateResponse = try await task.value

        #expect(firstResponse == secondResponse)
        #expect(secondResponse == lateResponse)
        #expect(firstResponse.requestID == task.requestID)
        #expect(decodeCount.withLock { $0 } == 1)
        #expect(await transport.executionCount == 1)
    }

    @Test("shared task stores one failure for late awaiters")
    func sharedTaskStoresFailureForLateAwaiters() async throws {
        let transport = ControlledNetworkTransport(outcome: .failure(.expectedFailure), gated: false)
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = try client.task(for: makeRequest())

        do {
            _ = try await task.value
            Issue.record("Expected the shared task to fail")
        } catch let error as ControlledTransportError {
            #expect(error == .expectedFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await task.value
            Issue.record("Expected the late awaiter to receive the stored failure")
        } catch let error as ControlledTransportError {
            #expect(error == .expectedFailure)
        } catch {
            Issue.record("Unexpected late-await error: \(error)")
        }

        #expect(await transport.executionCount == 1)
    }

    @Test("cancelling one value waiter leaves the shared operation running")
    func cancellingOneValueWaiterDoesNotCancelSharedOperation() async throws {
        let requestID = RequestID(rawValue: UUID())
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x2a]),
                HTTPResponse(status: .init(code: 200)),
            ),
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(FixedRequestIDGenerator(requestID: requestID)),
        )
        let task = try client.task(for: makeRequest())
        await transport.waitForStart()

        let cancelledWaiter = Task { try await task.value }
        let survivingWaiter = Task { try await task.value }
        await Task.yield()
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            Issue.record("Expected the cancelled waiter to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected waiter-cancellation error: \(error)")
        }

        #expect(await transport.cancellationCount == 0)
        await transport.releaseSuccess()

        let response = try await survivingWaiter.value
        #expect(response.requestID == requestID)
        #expect(await transport.executionCount == 1)
    }

    @Test("explicit task cancellation is idempotent and stored")
    func explicitTaskCancellationIsIdempotentAndStored() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x2a]),
                HTTPResponse(status: .init(code: 200)),
            ),
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = try client.task(for: makeRequest())
        await transport.waitForStart()

        let currentWaiter = Task { try await task.value }
        await Task.yield()
        task.cancel()
        task.cancel()

        do {
            _ = try await currentWaiter.value
            Issue.record("Expected current awaiter cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected current-await error: \(error)")
        }

        do {
            _ = try await task.value
            Issue.record("Expected future awaiter cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected future-await error: \(error)")
        }

        await transport.waitForCancellation()
        #expect(await transport.cancellationCount == 1)
        #expect(await transport.executionCount == 1)
    }

    @Test("cancelling send cancels its exclusively owned task")
    func sendCallerCancellationCancelsSharedOperation() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x2a]),
                HTTPResponse(status: .init(code: 200)),
            ),
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let sendTask = Task { try await client.send(makeRequest()) }
        await transport.waitForStart()

        sendTask.cancel()

        do {
            _ = try await sendTask.value
            Issue.record("Expected send cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected send-cancellation error: \(error)")
        }

        await transport.waitForCancellation()
        #expect(await transport.cancellationCount == 1)
        #expect(await transport.executionCount == 1)
    }

    @Test("send surfaces cancellation when its caller is already cancelled")
    func sendCallerAlreadyCancelledSurfacesCancellationError() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x2a]),
                HTTPResponse(status: .init(code: 200)),
            ),
            gated: false,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let gate = CancellationGate()
        let sendTask = Task {
            await gate.wait()
            return try await client.send(makeRequest())
        }

        await gate.waitUntilWaiting()
        sendTask.cancel()
        await gate.open()

        do {
            _ = try await sendTask.value
            Issue.record("Expected send to surface CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected pre-cancelled-send error: \(error)")
        }
    }

    @Test("executing one Request twice creates independent logical executions")
    func sameRequestCreatesIndependentLogicalExecutions() async throws {
        let firstID = RequestID(rawValue: UUID())
        let secondID = RequestID(rawValue: UUID())
        let generator = SequenceRequestIDGenerator(ids: [firstID, secondID])
        let transport = ControlledNetworkTransport(
            outcome: .success(
                Data([0x01]),
                HTTPResponse(status: .init(code: 200)),
            ),
            gated: false,
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRequestIDGenerator(generator),
        )
        let request = try makeRequest()

        let first = try await client.send(request)
        let second = try await client.send(request)

        #expect(first.requestID == firstID)
        #expect(second.requestID == secondID)
        #expect(first != second)
        #expect(await transport.executionCount == 2)
    }
}

private enum ControlledTransportError: Error, Equatable, Sendable {
    case expectedFailure
}

private actor CancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    func waitUntilWaiting() async {
        guard isWaiting == false else {
            return
        }

        await withCheckedContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ControlledNetworkTransport: NetworkTransport {
    enum Outcome: Sendable {
        case success(Data, HTTPResponse)
        case failure(ControlledTransportError)
    }

    private let outcome: Outcome
    private let gated: Bool
    private var pending: CheckedContinuation<(Data, HTTPResponse), any Error>?
    private var requestCount = 0
    private var cancellationCountValue = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(outcome: Outcome, gated: Bool = true) {
        self.outcome = outcome
        self.gated = gated
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        requestCount += 1
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStartWaiters {
            waiter.resume()
        }

        guard gated else {
            return try result()
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
            }
        }, onCancel: {
            Task { await self.cancelPending() }
        })
    }

    func waitForStart() async {
        guard requestCount == 0 else {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSuccess() {
        guard case let .success(data, response) = outcome else {
            preconditionFailure("The controlled transport does not contain a success")
        }
        guard let pending else {
            preconditionFailure("The controlled transport has not started")
        }

        self.pending = nil
        pending.resume(returning: (data, response))
    }

    func waitForCancellation() async {
        guard cancellationCountValue == 0 else {
            return
        }

        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    var executionCount: Int {
        requestCount
    }

    var cancellationCount: Int {
        cancellationCountValue
    }

    private func result() throws -> (Data, HTTPResponse) {
        switch outcome {
        case let .success(data, response):
            return (data, response)
        case let .failure(error):
            throw error
        }
    }

    private func cancelPending() {
        cancellationCountValue += 1
        let pendingCancellationWaiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in pendingCancellationWaiters {
            waiter.resume()
        }
        guard let pending else {
            return
        }

        self.pending = nil
        pending.resume(throwing: CancellationError())
    }
}

private struct FixedRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private final class CountingRequestIDGenerator: RequestIDGenerator, Sendable {
    let requestID: RequestID
    private let state = Mutex(0)

    init(requestID: RequestID) {
        self.requestID = requestID
    }

    var callCount: Int {
        state.withLock { $0 }
    }

    func generateRequestID() -> RequestID {
        state.withLock { $0 += 1 }
        return requestID
    }
}

private final class SequenceRequestIDGenerator: RequestIDGenerator, Sendable {
    private let ids: [RequestID]
    private let state = Mutex(0)

    init(ids: [RequestID]) {
        precondition(ids.isEmpty == false)
        self.ids = ids
    }

    func generateRequestID() -> RequestID {
        state.withLock { index in
            guard index < ids.count else {
                preconditionFailure("The test RequestID sequence was exhausted")
            }

            let requestID = ids[index]
            index += 1
            return requestID
        }
    }
}

private func makeRequest(
    response: ResponseDecoding<Data> = .data,
) throws -> Request<Data> {
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/request-id"))),
        response: response,
    )
    return Request(endpoint: endpoint)
}
