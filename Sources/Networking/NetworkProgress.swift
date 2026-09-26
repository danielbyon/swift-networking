//
//  NetworkProgress.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// The latest byte-transfer state for one logical network execution.
public struct NetworkProgress: Sendable, Equatable {
    /// The one-based transport attempt number, or `nil` before an attempt starts.
    public let attemptNumber: UInt?

    /// The number of request-body bytes sent during the current attempt.
    public let bytesSent: Int64

    /// The known request-body byte total for the current attempt, or `nil` when unknown.
    public let expectedBytesToSend: Int64?

    /// The number of response-body bytes received during the current attempt.
    public let bytesReceived: Int64

    /// The known response-body byte total for the current attempt, or `nil` when unknown.
    public let expectedBytesToReceive: Int64?

    /// Whether the complete logical operation, including validation and decoding, succeeded.
    public let isComplete: Bool

    /// The fraction of the current attempt's expected request-body bytes that were sent.
    ///
    /// This value is `nil` when the expected total is unknown or not positive. Otherwise,
    /// it is finite and clamped to the range `0...1`.
    public var uploadFractionCompleted: Double? {
        Self.fraction(bytes: bytesSent, expectedBytes: expectedBytesToSend)
    }

    /// The fraction of the current attempt's expected response-body bytes that were received.
    ///
    /// This value is `nil` when the expected total is unknown or not positive. Otherwise,
    /// it is finite and clamped to the range `0...1`.
    public var downloadFractionCompleted: Double? {
        Self.fraction(bytes: bytesReceived, expectedBytes: expectedBytesToReceive)
    }

    package init(
        attemptNumber: UInt?,
        bytesSent: Int64,
        expectedBytesToSend: Int64?,
        bytesReceived: Int64,
        expectedBytesToReceive: Int64?,
        isComplete: Bool,
    ) {
        self.attemptNumber = attemptNumber
        self.bytesSent = bytesSent
        self.expectedBytesToSend = expectedBytesToSend
        self.bytesReceived = bytesReceived
        self.expectedBytesToReceive = expectedBytesToReceive
        self.isComplete = isComplete
    }

    private static func fraction(bytes: Int64, expectedBytes: Int64?) -> Double? {
        guard let expectedBytes, expectedBytes > 0 else {
            return nil
        }

        let ratio = Double(bytes) / Double(expectedBytes)
        guard ratio.isFinite else {
            return nil
        }

        return min(max(ratio, 0), 1)
    }
}

/// A reusable stream of the latest transfer state for a network task.
///
/// Each iterator subscribes independently. An iterator buffers only its newest unseen update,
/// while successful completion is always delivered before that iterator finishes.
public struct NetworkProgressSequence: AsyncSequence, Sendable {
    /// The type of values produced by this progress sequence.
    public typealias Element = NetworkProgress

    /// An independent subscription to the current progress state.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<NetworkProgress>.Iterator

        fileprivate init(iterator: AsyncStream<NetworkProgress>.Iterator) {
            self.iterator = iterator
        }

        /// Returns the next available progress state, or `nil` after this subscription finishes.
        public mutating func next() async -> NetworkProgress? {
            await iterator.next()
        }
    }

    private let coordinator: NetworkProgressCoordinator

    fileprivate init(coordinator: NetworkProgressCoordinator) {
        self.coordinator = coordinator
    }

    /// Creates an independent subscription to the latest state of the logical request.
    public func makeAsyncIterator() -> AsyncIterator {
        let subscriptionID = UUID()
        let stream = AsyncStream<NetworkProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak coordinator] _ in
                coordinator?.unsubscribe(subscriptionID)
            }
            coordinator.subscribe(continuation, id: subscriptionID)
        }
        return AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

/// Reports URLSession byte callbacks to one logical task's shared progress state.
package struct NetworkProgressReporter: Sendable {
    private let coordinator: NetworkProgressCoordinator

    fileprivate init(coordinator: NetworkProgressCoordinator) {
        self.coordinator = coordinator
    }

    package func startAttempt(attemptNumber: UInt, expectedBytesToSend: Int64?) {
        coordinator.startAttempt(
            attemptNumber: attemptNumber,
            expectedBytesToSend: Self.usableExpectedBytes(expectedBytesToSend),
        )
    }

    package func updateUpload(bytesSent: Int64, expectedBytesToSend: Int64?) {
        coordinator.updateUpload(
            bytesSent: bytesSent,
            expectedBytesToSend: Self.usableExpectedBytes(expectedBytesToSend),
        )
    }

    package func updateDownload(bytesReceived: Int64, expectedBytesToReceive: Int64?) {
        coordinator.updateDownload(
            bytesReceived: bytesReceived,
            expectedBytesToReceive: Self.usableExpectedBytes(expectedBytesToReceive),
        )
    }

    private static func usableExpectedBytes(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else {
            return nil
        }

        return value
    }
}

/// Serializes progress publication and maintains the latest state plus active iterators.
final class NetworkProgressCoordinator: Sendable {
    private enum Completion: Sendable {
        case active
        case succeeded
        case failed
    }

    private struct State: Sendable {
        var latest = NetworkProgress(
            attemptNumber: nil,
            bytesSent: 0,
            expectedBytesToSend: nil,
            bytesReceived: 0,
            expectedBytesToReceive: nil,
            isComplete: false,
        )
        var completion = Completion.active
        var subscribers: [UUID: AsyncStream<NetworkProgress>.Continuation] = [:]
    }

    private let emissionLock = Mutex(())
    private let state = Mutex(State())

    var progress: NetworkProgressSequence {
        NetworkProgressSequence(coordinator: self)
    }

    var reporter: NetworkProgressReporter {
        NetworkProgressReporter(coordinator: self)
    }

    func startAttempt(attemptNumber: UInt, expectedBytesToSend: Int64?) {
        publish { _ in
            NetworkProgress(
                attemptNumber: attemptNumber,
                bytesSent: 0,
                expectedBytesToSend: expectedBytesToSend,
                bytesReceived: 0,
                expectedBytesToReceive: nil,
                isComplete: false,
            )
        }
    }

    func updateUpload(bytesSent: Int64, expectedBytesToSend: Int64?) {
        publish { current in
            NetworkProgress(
                attemptNumber: current.attemptNumber,
                bytesSent: bytesSent,
                expectedBytesToSend: expectedBytesToSend ?? current.expectedBytesToSend,
                bytesReceived: current.bytesReceived,
                expectedBytesToReceive: current.expectedBytesToReceive,
                isComplete: false,
            )
        }
    }

    func updateDownload(bytesReceived: Int64, expectedBytesToReceive: Int64?) {
        publish { current in
            NetworkProgress(
                attemptNumber: current.attemptNumber,
                bytesSent: current.bytesSent,
                expectedBytesToSend: current.expectedBytesToSend,
                bytesReceived: bytesReceived,
                expectedBytesToReceive: expectedBytesToReceive ?? current.expectedBytesToReceive,
                isComplete: false,
            )
        }
    }

    func finish(successfully: Bool) {
        emissionLock.withLock { _ in
            let (terminalProgress, continuations) = state.withLock { storage -> (
                NetworkProgress?,
                [AsyncStream<NetworkProgress>.Continuation],
            ) in
                guard storage.completion == .active else {
                    return (nil, [])
                }

                storage.completion = successfully ? .succeeded : .failed
                if successfully {
                    storage.latest = NetworkProgress(
                        attemptNumber: storage.latest.attemptNumber,
                        bytesSent: storage.latest.bytesSent,
                        expectedBytesToSend: storage.latest.expectedBytesToSend,
                        bytesReceived: storage.latest.bytesReceived,
                        expectedBytesToReceive: storage.latest.expectedBytesToReceive,
                        isComplete: true,
                    )
                    return (storage.latest, Array(storage.subscribers.values))
                }

                return (nil, Array(storage.subscribers.values))
            }

            if let terminalProgress {
                for continuation in continuations {
                    continuation.yield(terminalProgress)
                }
            }
            for continuation in continuations {
                continuation.finish()
            }
        }
    }

    func subscribe(
        _ continuation: AsyncStream<NetworkProgress>.Continuation,
        id: UUID,
    ) {
        emissionLock.withLock { _ in
            let (initialProgress, shouldFinish) = state.withLock { storage -> (NetworkProgress?, Bool) in
                switch storage.completion {
                case .active:
                    storage.subscribers[id] = continuation
                    return (storage.latest, false)
                case .succeeded:
                    return (storage.latest, true)
                case .failed:
                    return (nil, true)
                }
            }

            if let initialProgress {
                continuation.yield(initialProgress)
            }
            if shouldFinish {
                continuation.finish()
            }
        }
    }

    func unsubscribe(_ id: UUID) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
    }

    private func publish(_ update: (NetworkProgress) -> NetworkProgress) {
        emissionLock.withLock { _ in
            let (latest, continuations) = state.withLock { storage -> (
                NetworkProgress?,
                [AsyncStream<NetworkProgress>.Continuation],
            ) in
                guard storage.completion == .active else {
                    return (nil, [])
                }

                storage.latest = update(storage.latest)
                return (storage.latest, Array(storage.subscribers.values))
            }

            guard let latest else {
                return
            }

            for continuation in continuations {
                continuation.yield(latest)
            }
        }
    }
}
