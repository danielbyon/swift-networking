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
        let continuation: CheckedContinuation<NetworkEvent, any Error>
    }

    /// The outcome of one attempt to register a terminal waiter.
    private enum WaiterAdmission: Sendable {
        /// The terminal event was already delivered and needs no registration.
        case recorded(NetworkEvent)

        /// The waiting task was cancelled before it registered.
        case cancelled

        /// The waiter is registered and resumes when the event arrives.
        case registered
    }

    private struct State: Sendable {
        var events: [NetworkEvent] = []
        var terminalWaiters: [RequestID: [TerminalWaiter]] = [:]
        var cancelledWaiterIDs: Set<UUID> = []
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
                waiter.continuation.resume(returning: event)
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
    /// The method returns immediately when the terminal event was already delivered, so tests do not
    /// race asynchronous observer delivery.
    ///
    /// - Parameter requestID: The logical execution whose terminal event should be observed.
    /// - Returns: The delivered `requestCompleted`, `requestFailed`, or `requestCancelled` event.
    /// - Throws: `CancellationError` when the waiting task is cancelled before the event arrives.
    public func waitForTerminalEvent(for requestID: RequestID) async throws -> NetworkEvent {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let admission = state.withLock { state -> WaiterAdmission in
                    if let recorded = state.events.first(where: {
                        $0.recordedRequestID == requestID && $0.isTerminalRecordedEvent
                    }) {
                        return .recorded(recorded)
                    }

                    if state.cancelledWaiterIDs.remove(waiterID) != nil {
                        return .cancelled
                    }

                    state.terminalWaiters[requestID, default: []].append(
                        TerminalWaiter(id: waiterID, continuation: continuation),
                    )
                    return .registered
                }

                switch admission {
                case let .recorded(event):
                    continuation.resume(returning: event)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .registered:
                    break
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> TerminalWaiter? in
                guard var waiters = state.terminalWaiters[requestID],
                      let index = waiters.firstIndex(where: { $0.id == waiterID })
                else {
                    let hasTerminalEvent = state.events.contains {
                        $0.recordedRequestID == requestID && $0.isTerminalRecordedEvent
                    }
                    if hasTerminalEvent == false {
                        state.cancelledWaiterIDs.insert(waiterID)
                    }
                    return nil
                }

                let waiter = waiters.remove(at: index)
                state.terminalWaiters[requestID] = waiters.isEmpty ? nil : waiters
                return waiter
            }
            cancelled?.continuation.resume(throwing: CancellationError())
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
