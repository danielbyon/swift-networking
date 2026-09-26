//
//  NetworkProgressTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct NetworkProgressTests {
    @Test("Task progress replays current state to independent iterators and preserves success")
    func taskProgressReplaysLatestStateAndPreservesSuccessfulTerminalValue() async throws {
        let requestID = RequestID(rawValue: UUID())
        let gate = ProgressGate()
        let task = NetworkTask<Data>(requestID: requestID) { reporter in
            await gate.waitForStart()
            reporter.startAttempt(attemptNumber: 1, expectedBytesToSend: 10)
            reporter.updateUpload(bytesSent: 2, expectedBytesToSend: 10)
            reporter.updateDownload(bytesReceived: 3, expectedBytesToReceive: 10)
            reporter.updateUpload(bytesSent: 7, expectedBytesToSend: 10)
            await gate.markUpdatesReady()
            await gate.waitForRelease()
            return Response(
                value: Data([0x2a]),
                httpResponse: HTTPResponse(status: .init(code: 200)),
                requestID: requestID,
            )
        }

        let sequence = task.progress
        var firstIterator = sequence.makeAsyncIterator()
        let initial = await firstIterator.next()
        #expect(initial?.attemptNumber == nil)
        #expect(initial?.bytesSent == 0)
        #expect(initial?.bytesReceived == 0)
        #expect(initial?.isComplete == false)

        await gate.start()
        await gate.waitForUpdates()
        let coalesced = await firstIterator.next()
        #expect(coalesced?.attemptNumber == 1)
        #expect(coalesced?.bytesSent == 7)
        #expect(coalesced?.bytesReceived == 3)
        #expect(coalesced?.isComplete == false)

        var secondIterator = task.progress.makeAsyncIterator()
        let replayed = await secondIterator.next()
        #expect(replayed?.bytesSent == 7)
        #expect(replayed?.bytesReceived == 3)

        await gate.release()
        let terminal = await firstIterator.next()
        let secondTerminal = await secondIterator.next()
        #expect(terminal?.isComplete == true)
        #expect(terminal?.bytesSent == 7)
        #expect(secondTerminal?.isComplete == true)
        #expect(await firstIterator.next() == nil)
        #expect(await secondIterator.next() == nil)
        #expect(try await task.value.value == Data([0x2a]))

        var lateIterator = sequence.makeAsyncIterator()
        #expect(await lateIterator.next()?.isComplete == true)
        #expect(await lateIterator.next() == nil)
    }

    @Test("Cancelling one progress iterator does not cancel the shared operation")
    func cancellingProgressIteratorUnsubscribesOnlyThatObserver() async throws {
        let requestID = RequestID(rawValue: UUID())
        let gate = ProgressGate()
        let task = NetworkTask<Data>(requestID: requestID) { reporter in
            await gate.waitForStart()
            reporter.startAttempt(attemptNumber: 1, expectedBytesToSend: nil)
            await gate.markUpdatesReady()
            await gate.waitForRelease()
            return Response(
                value: Data([0x01]),
                httpResponse: HTTPResponse(status: .init(code: 200)),
                requestID: requestID,
            )
        }

        var survivingIterator = task.progress.makeAsyncIterator()
        #expect(await survivingIterator.next()?.attemptNumber == nil)
        await gate.start()
        await gate.waitForUpdates()

        let cancelledObserver = Task {
            var iterator = task.progress.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()
        }
        await Task.yield()
        cancelledObserver.cancel()
        #expect(await cancelledObserver.value == nil)

        await gate.release()
        #expect(try await task.value.value == Data([0x01]))
        #expect(await survivingIterator.next()?.isComplete == true)
    }

    @Test("Late progress subscribers complete immediately after operation failure")
    func lateProgressSubscriberDoesNotReplayFailureState() async throws {
        let task = NetworkTask<Data>(requestID: RequestID(rawValue: UUID())) { reporter in
            reporter.startAttempt(attemptNumber: 1, expectedBytesToSend: nil)
            reporter.updateDownload(bytesReceived: 5, expectedBytesToReceive: 5)
            throw ProgressTestError.expectedFailure
        }

        do {
            _ = try await task.value
            Issue.record("Expected the network task to fail")
        } catch is ProgressTestError {
            // The value failure synchronizes the assertion with progress completion.
        } catch {
            Issue.record("Unexpected task error: \(error)")
        }

        var iterator = task.progress.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("Progress fractions are unavailable when expected totals are unknown or unusable")
    func fractionsRequirePositiveExpectedTotals() {
        let unknown = NetworkProgress(
            attemptNumber: 1,
            bytesSent: 4,
            expectedBytesToSend: nil,
            bytesReceived: 8,
            expectedBytesToReceive: nil,
            isComplete: false,
        )
        let zeroExpected = NetworkProgress(
            attemptNumber: 1,
            bytesSent: 4,
            expectedBytesToSend: 0,
            bytesReceived: 8,
            expectedBytesToReceive: 0,
            isComplete: false,
        )
        let negativeExpected = NetworkProgress(
            attemptNumber: 1,
            bytesSent: 4,
            expectedBytesToSend: -1,
            bytesReceived: 8,
            expectedBytesToReceive: -1,
            isComplete: false,
        )

        #expect(unknown.uploadFractionCompleted == nil)
        #expect(unknown.downloadFractionCompleted == nil)
        #expect(zeroExpected.uploadFractionCompleted == nil)
        #expect(zeroExpected.downloadFractionCompleted == nil)
        #expect(negativeExpected.uploadFractionCompleted == nil)
        #expect(negativeExpected.downloadFractionCompleted == nil)
    }

    @Test("Progress fractions are finite and clamped without changing raw counters")
    func fractionsClampRatiosAndPreserveByteCounters() {
        let progress = NetworkProgress(
            attemptNumber: 2,
            bytesSent: 30,
            expectedBytesToSend: 20,
            bytesReceived: -3,
            expectedBytesToReceive: 10,
            isComplete: false,
        )

        #expect(progress.uploadFractionCompleted == 1)
        #expect(progress.downloadFractionCompleted == 0)
        #expect(progress.uploadFractionCompleted?.isFinite == true)
        #expect(progress.downloadFractionCompleted?.isFinite == true)
        #expect(progress.bytesSent == 30)
        #expect(progress.bytesReceived == -3)
    }

    @Test("Progress fractions preserve ratios for positive expected totals")
    func fractionsReportPositiveRatios() {
        let progress = NetworkProgress(
            attemptNumber: 1,
            bytesSent: 25,
            expectedBytesToSend: 100,
            bytesReceived: 3,
            expectedBytesToReceive: 12,
            isComplete: false,
        )

        #expect(progress.uploadFractionCompleted == 0.25)
        #expect(progress.downloadFractionCompleted == 0.25)
    }
}

private enum ProgressTestError: Error {
    case expectedFailure
}

private actor ProgressGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var updatesReady = false
    private var released = false
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func start() {
        started = true
        resume(&startWaiters)
    }

    func waitForStart() async {
        guard !started else {
            return
        }

        await withCheckedContinuation { startWaiters.append($0) }
    }

    func markUpdatesReady() {
        updatesReady = true
        resume(&updateWaiters)
    }

    func waitForUpdates() async {
        guard !updatesReady else {
            return
        }

        await withCheckedContinuation { updateWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else {
            return
        }

        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        resume(&releaseWaiters)
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
