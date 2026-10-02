//
//  NetworkProgressRecorder.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking
import Synchronization

/// Retains the progress states a network task publishes for assertion history.
///
/// The recorder consumes the normal `NetworkTask.progress` multicast sequence. Production
/// `NetworkTask` keeps only the latest state, while this recorder retains every state the
/// sequence delivers. The sequence buffers only its newest unseen update for each subscriber, so
/// mock transfers that publish several updates without pausing can coalesce; configure stub latency
/// pause points when a test must observe every scripted update.
public final class NetworkProgressRecorder: Sendable {
    private struct UpdateWaiter: Sendable {
        let id: UUID
        let predicate: @Sendable (NetworkProgress) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var recorded: [NetworkProgress] = []
        var isFinished = false
        /// Monotonic publication counter. It changes whenever `recorded` grows, so a wait that
        /// snapshotted the history can detect a publication that raced its registration.
        var version = 0
        var updateWaiters: [UpdateWaiter] = []
        var finishWaiters: [CheckedContinuation<Void, Never>] = []
    }

    /// A consistent view of the published history used to evaluate a caller predicate.
    private struct HistorySnapshot: Sendable {
        let recorded: [NetworkProgress]
        let version: Int
        let isFinished: Bool
    }

    private let state = Mutex(State())

    /// Creates an empty recorder.
    public init() {}

    /// Starts consuming the supplied progress sequence until it finishes.
    ///
    /// The recorder subscribes before this method returns, so an update the sequence publishes
    /// after the call reaches the recording task instead of being missed. Recording continues on
    /// an internal task that callers do not manage.
    ///
    /// - Parameter progress: The progress sequence to record.
    public func startRecording(_ progress: NetworkProgressSequence) {
        let iterator = progress.makeAsyncIterator()

        Task {
            var iterator = iterator

            while let update = await iterator.next() {
                // Phase one publishes the update and snapshots the waiters that must evaluate it.
                // Caller-supplied predicates never run while the mutex is held, because a predicate
                // may call back into the recorder.
                let waiters = self.state.withLock { state -> [UpdateWaiter] in
                    state.recorded.append(update)
                    state.version += 1
                    return state.updateWaiters
                }

                let matchingIDs = Set(waiters.lazy.filter { $0.predicate(update) }.map(\.id))
                guard matchingIDs.isEmpty == false else {
                    continue
                }

                // Phase two claims only the waiters that are still pending and whose predicate
                // matched this update. Waiters registered after the snapshot keep waiting, because
                // they observe the new state through their own history snapshot.
                let readyWaiters = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    var ready: [CheckedContinuation<Void, Never>] = []
                    var remaining: [UpdateWaiter] = []
                    for waiter in state.updateWaiters {
                        if matchingIDs.contains(waiter.id) {
                            ready.append(waiter.continuation)
                        } else {
                            remaining.append(waiter)
                        }
                    }
                    state.updateWaiters = remaining
                    return ready
                }
                for waiter in readyWaiters {
                    waiter.resume()
                }
            }

            let (updateWaiters, finishWaiters) = self.state.withLock { state -> (
                [CheckedContinuation<Void, Never>],
                [CheckedContinuation<Void, Never>],
            ) in
                state.isFinished = true
                let updateWaiters = state.updateWaiters.map(\.continuation)
                state.updateWaiters.removeAll()
                let finishWaiters = state.finishWaiters
                state.finishWaiters.removeAll()
                return (updateWaiters, finishWaiters)
            }
            for waiter in updateWaiters {
                waiter.resume()
            }
            for waiter in finishWaiters {
                waiter.resume()
            }
        }
    }

    /// Returns every progress state the recorder has received in publication order.
    public func recordedProgress() -> [NetworkProgress] {
        state.withLock(\.recorded)
    }

    /// Waits until the recorder has received a state that satisfies the predicate.
    ///
    /// The predicate is evaluated against every state as it arrives, and against the states that
    /// are already recorded when this method is called. The wait also ends when the recorded
    /// sequence has finished.
    ///
    /// - Parameter predicate: The condition a recorded state must satisfy.
    public func waitUntilRecorded(_ predicate: @escaping @Sendable (NetworkProgress) -> Bool) async {
        while true {
            let snapshot = state.withLock { state in
                HistorySnapshot(
                    recorded: state.recorded,
                    version: state.version,
                    isFinished: state.isFinished,
                )
            }

            // The predicate runs without the mutex held so it can re-enter the recorder.
            if snapshot.isFinished {
                return
            }
            if snapshot.recorded.contains(where: predicate) {
                return
            }

            var didRegister = false
            await withCheckedContinuation { continuation in
                // Registration revalidates the snapshot version so a publication or completion
                // that raced the predicate cannot be missed.
                didRegister = state.withLock { state -> Bool in
                    guard state.version == snapshot.version, state.isFinished == false else {
                        return false
                    }

                    state.updateWaiters.append(
                        UpdateWaiter(id: UUID(), predicate: predicate, continuation: continuation),
                    )
                    return true
                }
                if didRegister == false {
                    continuation.resume()
                }
            }

            if didRegister {
                // A matching state was recorded or the sequence finished while the waiter was
                // pending, so the wait contract is already satisfied.
                return
            }
        }
    }

    /// Waits until the recorded progress sequence finishes.
    ///
    /// The sequence finishes when the logical execution reaches its terminal state.
    public func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                guard state.isFinished == false else {
                    return true
                }

                state.finishWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
