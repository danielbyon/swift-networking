//
//  NetworkEventRecorder.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking
import Synchronization

/// Records lifecycle events delivered through a normal `NetworkEventObserver`.
///
/// The recorder appends each event synchronously when the delivery queue calls the observer, so the
/// recorded order matches the order each observer receives. Request execution never waits for
/// observers, so tests that must observe completion, failure, or cancellation of a finished request
/// use `waitForTerminalEvent(for:)` instead of reading the recorded history immediately.
public final class NetworkEventRecorder: Sendable {
    private struct TerminalWaiter: Sendable {
        let id: UUID
        let continuation: AsyncThrowingStream<NetworkEvent, any Error>.Continuation
    }

    /// The outcome of one attempt to register a terminal waiter.
    private enum WaiterAdmission: Sendable {
        /// The terminal event was already delivered and needs no registration.
        case recorded(NetworkEvent)

        /// The waiter is registered and resumes when the event arrives.
        case registered
    }

    private struct State: Sendable {
        var events: [NetworkEvent] = []
        var terminalWaiters: [RequestID: [TerminalWaiter]] = [:]
    }

    private let state = Mutex(State())

    /// Creates an empty recorder.
    public init() {}

    /// An observer that records every event delivered to it.
    ///
    /// Register the observer through `Configuration.withEventObserver(_:)`. The observer appends
    /// events synchronously and resumes terminal waiters, and it never blocks event delivery.
    public var observer: NetworkEventObserver {
        NetworkEventObserver { event in
            let waiters = self.state.withLock { state -> [TerminalWaiter] in
                state.events.append(event)
                guard event.isTerminalRecordedEvent else {
                    return []
                }

                return state.terminalWaiters.removeValue(forKey: event.recordedRequestID) ?? []
            }
            for waiter in waiters {
                waiter.continuation.yield(event)
                waiter.continuation.finish()
            }
        }
    }

    /// Returns every event the recorder has received in delivery order.
    public func recordedEvents() -> [NetworkEvent] {
        state.withLock(\.events)
    }

    /// Returns the events the recorder received for one logical execution in delivery order.
    ///
    /// - Parameter requestID: The logical execution identity to filter by.
    public func recordedEvents(for requestID: RequestID) -> [NetworkEvent] {
        state.withLock { state in
            state.events.filter { $0.recordedRequestID == requestID }
        }
    }

    /// Waits for the terminal event of one logical execution.
    ///
    /// The method resumes immediately with the terminal event when it was already delivered, so
    /// tests do not race the asynchronous observer delivery. A task that is already cancelled when
    /// the wait begins throws `CancellationError` instead of returning that recorded event, and a
    /// waiter that is cancelled while it is still waiting is claimed by the cancellation rather
    /// than by the event, so every waiter observes exactly one outcome.
    ///
    /// The recorder resolves a waiter against the first terminal event recorded for `requestID`,
    /// and it cannot distinguish separate executions that reuse one request identity. Give each
    /// execution a distinct identity when a test waits more than once: `StaticRequestIDGenerator`
    /// suits single-execution tests, while `SequenceRequestIDGenerator` allocates one identity per
    /// execution.
    ///
    /// - Parameter requestID: The logical execution identity whose terminal event should be observed.
    /// - Returns: The delivered `requestCompleted`, `requestFailed`, or `requestCancelled` event.
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    public func waitForTerminalEvent(for requestID: RequestID) async throws -> NetworkEvent {
        try Task.checkCancellation()

        let waiterID = UUID()
        let (events, continuation) = AsyncThrowingStream<NetworkEvent, any Error>.makeStream()

        let admission = state.withLock { state -> WaiterAdmission in
            if let recorded = state.events.first(where: {
                $0.recordedRequestID == requestID && $0.isTerminalRecordedEvent
            }) {
                return .recorded(recorded)
            }

            state.terminalWaiters[requestID, default: []].append(
                TerminalWaiter(id: waiterID, continuation: continuation),
            )
            return .registered
        }

        if case let .recorded(event) = admission {
            return event
        }

        return try await withTaskCancellationHandler {
            for try await event in events {
                return event
            }

            throw CancellationError()
        } onCancel: {
            let cancelled = state.withLock { state -> TerminalWaiter? in
                guard var waiters = state.terminalWaiters[requestID],
                      let index = waiters.firstIndex(where: { $0.id == waiterID })
                else {
                    return nil
                }

                let waiter = waiters.remove(at: index)
                state.terminalWaiters[requestID] = waiters.isEmpty ? nil : waiters
                return waiter
            }
            cancelled?.continuation.finish(throwing: CancellationError())
        }
    }
}

extension NetworkEvent {
    /// The logical execution identity carried by every lifecycle event.
    fileprivate var recordedRequestID: RequestID {
        switch self {
        case let .requestStarted(event):
            event.requestID
        case let .attemptStarted(event):
            event.requestID
        case let .responseReceived(event):
            event.requestID
        case let .attemptFailed(event):
            event.requestID
        case let .authenticationReplayScheduled(event):
            event.requestID
        case let .retryScheduled(event):
            event.requestID
        case let .redirectDecision(event):
            event.requestID
        case let .requestCompleted(event):
            event.requestID
        case let .requestFailed(event):
            event.requestID
        case let .requestCancelled(event):
            event.requestID
        }
    }

    /// Whether this event is one of the three terminal lifecycle events.
    fileprivate var isTerminalRecordedEvent: Bool {
        switch self {
        case .requestCompleted,
             .requestFailed,
             .requestCancelled:
            true
        default:
            false
        }
    }
}
