//
//  RequestIDGenerators.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Networking
import Synchronization

/// A request identity generator that returns one configured identity for every logical execution.
///
/// Use this generator when a test must know in advance which identity every recorded attempt,
/// grouped recording, and lifecycle event carries.
public struct StaticRequestIDGenerator: RequestIDGenerator {
    /// The identity returned for every generated request.
    public let requestID: RequestID

    /// Creates a generator that always returns the supplied identity.
    ///
    /// - Parameter requestID: The identity assigned to every logical execution.
    public init(requestID: RequestID) {
        self.requestID = requestID
    }

    /// Returns the configured request identity.
    public func generateRequestID() -> RequestID {
        requestID
    }
}

/// A request identity generator that allocates a configured sequence of identities.
///
/// Consecutive logical executions receive the configured identities in order. Exhausting the
/// sequence is an explicit programming failure in a test: the generator must not recycle
/// identities, because recycled identities make per-execution recording, grouping, and event
/// assertions ambiguous. Configure one identity for every logical execution the test performs.
public struct SequenceRequestIDGenerator: RequestIDGenerator {
    private final class Storage: Sendable {
        private struct State: Sendable {
            let requestIDs: [RequestID]
            var nextIndex = 0
        }

        private let state: Mutex<State>

        init(requestIDs: [RequestID]) {
            state = Mutex(State(requestIDs: requestIDs))
        }

        var remainingCount: Int {
            state.withLock { $0.requestIDs.count - $0.nextIndex }
        }

        func generateRequestID() -> RequestID {
            state.withLock { state in
                guard state.nextIndex < state.requestIDs.count else {
                    preconditionFailure(
                        "SequenceRequestIDGenerator exhausted after allocating "
                            + "\(state.nextIndex) request IDs; configure one identity per logical execution.",
                    )
                }

                let requestID = state.requestIDs[state.nextIndex]
                state.nextIndex += 1
                return requestID
            }
        }
    }

    private let storage: Storage

    /// Creates a generator that returns the supplied identities in order.
    ///
    /// - Parameter requestIDs: The identities allocated by successive logical executions.
    public init(requestIDs: [RequestID]) {
        storage = Storage(requestIDs: requestIDs)
    }

    /// The number of configured identities that have not been allocated yet.
    public var remainingCount: Int {
        storage.remainingCount
    }

    /// Whether every configured identity has been allocated.
    public var isExhausted: Bool {
        remainingCount == 0
    }

    /// Returns the next configured request identity.
    ///
    /// - Warning: Traps when the configured sequence is exhausted.
    public func generateRequestID() -> RequestID {
        storage.generateRequestID()
    }
}
