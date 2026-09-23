//
//  NetworkTask.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

private final class NetworkTaskState<Value: Sendable>: Sendable {
    private struct Storage: Sendable {
        var terminalResult: Result<Response<Value>, any Error>?
        var waiters: [UUID: CheckedContinuation<Response<Value>, any Error>] = [:]
        var cancelledWaiters: Set<UUID> = []
    }

    private let storage = Mutex(Storage())

    func value(for waiterID: UUID) async throws -> Response<Value> {
        try await withCheckedThrowingContinuation { continuation in
            let immediateResult: Result<Response<Value>, any Error>? = storage.withLock { storage in
                if storage.cancelledWaiters.remove(waiterID) != nil {
                    return .failure(CancellationError())
                }

                if let terminalResult = storage.terminalResult {
                    return terminalResult
                }

                storage.waiters[waiterID] = continuation
                return nil
            }

            if let immediateResult {
                continuation.resume(with: immediateResult)
            }
        }
    }

    func cancelWaiter(_ waiterID: UUID) {
        var waiter: CheckedContinuation<Response<Value>, any Error>?

        storage.withLock { storage in
            if let removedWaiter = storage.waiters.removeValue(forKey: waiterID) {
                waiter = removedWaiter
            } else if storage.terminalResult == nil {
                storage.cancelledWaiters.insert(waiterID)
            }
        }

        waiter?.resume(throwing: CancellationError())
    }

    func complete(with result: Result<Response<Value>, any Error>) {
        var waiters: [CheckedContinuation<Response<Value>, any Error>] = []

        storage.withLock { storage in
            guard storage.terminalResult == nil else {
                return
            }

            storage.terminalResult = result
            waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
        }

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func cancelShared() -> Bool {
        var waiters: [CheckedContinuation<Response<Value>, any Error>] = []
        let cancellation = Result<Response<Value>, any Error>.failure(CancellationError())
        let didCancel = storage.withLock { storage in
            guard storage.terminalResult == nil else {
                return false
            }

            storage.terminalResult = cancellation
            waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            storage.cancelledWaiters.removeAll()
            return true
        }

        if didCancel {
            for waiter in waiters {
                waiter.resume(with: cancellation)
            }
        }
        return didCancel
    }
}

/// Represents one shared logical execution of a request.
public final class NetworkTask<Value: Sendable>: Sendable {
    /// The identity assigned to this logical execution.
    public let requestID: RequestID

    private let state: NetworkTaskState<Value>
    private let runner: Task<Void, Never>

    package init(
        requestID: RequestID,
        operation: @escaping @Sendable () async throws -> Response<Value>,
    ) {
        self.requestID = requestID
        let taskState = NetworkTaskState<Value>()
        state = taskState
        runner = Task {
            do {
                let response = try await operation()
                taskState.complete(with: .success(response))
            } catch {
                taskState.complete(with: .failure(error))
            }
        }
    }

    /// The stored terminal result of this logical execution.
    ///
    /// Multiple awaiters observe the same result without starting additional transport work.
    /// Cancelling the Swift task that is awaiting this property cancels only that waiter.
    public var value: Response<Value> {
        get async throws {
            let waiterID = UUID()
            return try await withTaskCancellationHandler(operation: {
                try await state.value(for: waiterID)
            }, onCancel: {
                state.cancelWaiter(waiterID)
            })
        }
    }

    /// Cancels the shared logical execution.
    ///
    /// Cancellation is idempotent. Current and future value awaiters receive
    /// `CancellationError` when this method wins the terminal-result race.
    public func cancel() {
        if state.cancelShared() {
            runner.cancel()
        }
    }
}
