//
//  StubLatency.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A test-controlled suspension point inside a mock transport attempt.
///
/// A stub can configure a latency control to model time a real transport spends before it publishes
/// its next observable action. Tests wait until the mock reaches a numbered pause point and then
/// release it, so attempt ordering is deterministic without wall-clock sleeps. Cancelling the
/// attempt while it is suspended resumes the mock with `CancellationError`, which lets tests assert
/// cancellation propagation and mock cancellation observation.
///
/// Pause points are numbered from one in the order the mock reaches them. A stub without scripted
/// progress reaches exactly one pause point before it produces its response; a stub with scripted
/// progress reaches one pause point before each scripted update and one further pause point before
/// it produces its response. A stub that serves several attempts reaches the same pause points once
/// per attempt, so tests coordinate repeated attempts by waiting for the occurrence they need.
public actor StubLatency {
    private struct Point: Sendable {
        /// A waiter that resumes once the point has been reached the requested number of times.
        struct ReachedWaiter: Sendable {
            let occurrence: Int
            let continuation: CheckedContinuation<Void, Never>
        }

        var reachedCount = 0
        var availableReleases = 0
        var suspendedWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var reachedWaiters: [ReachedWaiter] = []

        /// Removes and returns the waiters whose occurrence the latest reach satisfied.
        mutating func takeReachedWaiters() -> [ReachedWaiter] {
            var reached: [ReachedWaiter] = []
            var remaining: [ReachedWaiter] = []
            for waiter in reachedWaiters {
                if waiter.occurrence <= reachedCount {
                    reached.append(waiter)
                } else {
                    remaining.append(waiter)
                }
            }
            reachedWaiters = remaining
            return reached
        }
    }

    private var points: [Int: Point] = [:]

    /// Creates a latency control with no reached or released pause points.
    public init() {}

    /// Suspends the mock transport at the numbered pause point.
    ///
    /// The call returns immediately when the point was already released, and throws
    /// `CancellationError` when the attempt is cancelled before the point is released. A
    /// suspension that observes the cancellation while registering fails immediately instead of
    /// waiting for a release that would never resume it, and a cancellation that races a release
    /// still surfaces after the continuation resumes because the suspension re-checks the task's
    /// cancellation state before it returns. Calling this method is reserved for mock transport
    /// implementations.
    ///
    /// - Parameter point: The one-based pause-point number within the transport attempt.
    public func suspend(at point: Int) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var state = points[point] ?? Point()
                state.reachedCount += 1
                let reachedWaiters = state.takeReachedWaiters()
                let wasCancelledBeforeRegistration = Task.isCancelled
                let canPassThrough = !wasCancelledBeforeRegistration && state.availableReleases > 0
                if canPassThrough {
                    state.availableReleases -= 1
                } else if !wasCancelledBeforeRegistration {
                    state.suspendedWaiters[waiterID] = continuation
                }
                points[point] = state

                for waiter in reachedWaiters {
                    waiter.continuation.resume()
                }
                if wasCancelledBeforeRegistration {
                    continuation.resume(throwing: CancellationError())
                } else if canPassThrough {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelSuspension(at: point, waiterID: waiterID) }
        }

        // Cancellation cleanup reaches the actor through an independent task, so `release(at:)` can
        // resume this suspension before that cleanup runs. Re-checking after the continuation
        // resumes keeps a cancelled attempt from continuing past a pause point that a concurrent
        // release opened for it.
        try Task.checkCancellation()
    }

    /// Waits until the mock transport has reached the numbered pause point the requested number of times.
    ///
    /// The same pause point is reached again for every attempt served by a stub with this latency
    /// control, so a test that coordinates successive attempts waits for the occurrence that belongs
    /// to the attempt it is about to release. The wait returns immediately when the point was already
    /// reached that many times.
    ///
    /// - Parameters:
    ///   - point: The one-based pause-point number within the transport attempt.
    ///   - occurrence: The one-based number of reaches to wait for. Defaults to the first reach.
    public func waitUntilSuspended(at point: Int, occurrence: Int = 1) async {
        await withCheckedContinuation { continuation in
            var state = points[point] ?? Point()
            if state.reachedCount >= occurrence {
                continuation.resume()
            } else {
                state.reachedWaiters.append(
                    Point.ReachedWaiter(occurrence: occurrence, continuation: continuation),
                )
                points[point] = state
            }
        }
    }

    /// Releases the numbered pause point.
    ///
    /// A suspended attempt resumes, or the next attempt to reach the point passes through without
    /// waiting.
    ///
    /// - Parameter point: The one-based pause-point number within the transport attempt.
    public func release(at point: Int) {
        var state = points[point] ?? Point()
        guard let (waiterID, continuation) = state.suspendedWaiters.first else {
            state.availableReleases += 1
            points[point] = state
            return
        }

        state.suspendedWaiters.removeValue(forKey: waiterID)
        points[point] = state
        continuation.resume()
    }

    private func cancelSuspension(at point: Int, waiterID: UUID) {
        guard var state = points[point],
              let continuation = state.suspendedWaiters.removeValue(forKey: waiterID)
        else {
            // The suspension either has not registered yet, in which case it fails when it observes
            // the cancellation itself, or it has already returned and needs no resumption.
            return
        }

        points[point] = state
        continuation.resume(throwing: CancellationError())
    }
}
