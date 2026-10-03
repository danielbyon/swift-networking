//
//  CombineBridges.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

#if canImport(Combine)
import Combine
import Foundation
import Synchronization

extension NetworkClient {
    /// Creates a cold publisher that starts one logical request execution for each subscription.
    ///
    /// The request starts while the subscription is being established. Each subscription owns its
    /// `NetworkTask`, and cancelling it cancels that task.
    ///
    /// - Parameter request: The immutable request to execute for each subscription.
    /// - Returns: A publisher that emits the response or the request's error.
    public func publisher<Output: Sendable>(
        for request: Request<Output>,
    ) -> AnyPublisher<Response<Output>, Error> {
        Deferred { [self, request] in
            let task = task(for: request)
            return terminalPublisher(for: task, cancelsOwnedOperation: true)
        }
        .eraseToAnyPublisher()
    }
}

extension NetworkTask {
    /// Observes this task's stored terminal response or failure.
    ///
    /// Each subscriber owns an independent waiter. Cancelling a subscription cancels only its
    /// waiter and never cancels this shared task.
    public var valuePublisher: AnyPublisher<Response<Value>, Error> {
        Deferred { [self] in
            terminalPublisher(for: self, cancelsOwnedOperation: false)
        }
        .eraseToAnyPublisher()
    }

    /// Observes this task's replaying, latest-state progress sequence.
    ///
    /// Each subscriber observes the existing task independently. When demand is exhausted,
    /// intermediate progress states coalesce to the newest unseen state. Cancelling a subscription
    /// stops only its observation. Successful terminal progress is delivered before normal
    /// completion; failed or cancelled tasks complete normally without a successful terminal state.
    public var progressPublisher: AnyPublisher<NetworkProgress, Never> {
        Deferred { [self] in
            makeProgressPublisher(for: self)
        }
        .eraseToAnyPublisher()
    }
}

/// Replays one terminal result while keeping success demand-controlled and failures demand-free.
private final class TerminalRelay<Value: Sendable>: Sendable {
    private struct State {
        let subject = CurrentValueSubject<Response<Value>?, Error>(nil)
        var hasSentResult = false
        var isCancelled = false
    }

    private let deliveryLock = NSRecursiveLock()
    private let state = Mutex(State())

    var publisher: AnyPublisher<Response<Value>, Error> {
        state.withLock { state in
            state.subject
                .compactMap(\.self)
                .prefix(1)
                .eraseToAnyPublisher()
        }
    }

    func send(_ result: Result<Response<Value>, any Error>) {
        deliveryLock.withLock {
            let subject = state.withLock { state -> CurrentValueSubject<Response<Value>?, Error>? in
                guard !state.hasSentResult, !state.isCancelled else {
                    return nil
                }

                state.hasSentResult = true
                return state.subject
            }
            guard let subject else {
                return
            }

            switch result {
            case let .success(response):
                subject.send(.some(response))
            case let .failure(error):
                subject.send(completion: .failure(error))
            }
        }
    }

    func cancel() {
        deliveryLock.withLock {
            state.withLock { $0.isCancelled = true }
        }
    }
}

/// Owns a cancellable observation task without making cancellation depend on setup ordering.
private final class CombineObservation: Sendable {
    private struct State: Sendable {
        var task: Task<Void, Never>?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func install(_ task: Task<Void, Never>) {
        let cancelImmediately = state.withLock { state in
            guard !state.isCancelled else {
                return true
            }

            state.task = task
            return false
        }
        if cancelImmediately {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isCancelled = true
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }
}

private func terminalPublisher<Value: Sendable>(
    for task: NetworkTask<Value>,
    cancelsOwnedOperation: Bool,
) -> AnyPublisher<Response<Value>, Error> {
    let relay = TerminalRelay<Value>()
    let observation = CombineObservation()
    let observer = Task { [task, relay] in
        let result: Result<Response<Value>, any Error>
        do {
            let response = try await task.value
            result = .success(response)
        } catch {
            result = .failure(error)
        }
        relay.send(result)
    }
    observation.install(observer)

    return relay.publisher
        .handleEvents(receiveCancel: {
            observation.cancel()
            relay.cancel()
            if cancelsOwnedOperation {
                task.cancel()
            }
        })
        .eraseToAnyPublisher()
}

private struct ProgressEnvelope: Sendable {
    let generation: UInt64
    let progress: NetworkProgress
}

/// Uses Combine's latest-value storage while serializing subject access with its async observer.
private final class ProgressRelay: Sendable {
    private struct State {
        let subject = CurrentValueSubject<ProgressEnvelope?, Never>(nil)
        var generation: UInt64 = 0
        var isFinished = false
        var isCancelled = false
    }

    private let deliveryLock = NSRecursiveLock()
    private let state = Mutex(State())

    func publisher(
        acknowledge: @escaping @Sendable (UInt64) -> Void,
    ) -> AnyPublisher<NetworkProgress, Never> {
        state.withLock { state in
            state.subject
                .compactMap(\.self)
                .handleEvents(receiveOutput: { acknowledge($0.generation) })
                .map(\.progress)
                .eraseToAnyPublisher()
        }
    }

    func send(_ progress: NetworkProgress) -> UInt64? {
        deliveryLock.withLock {
            let delivery = state.withLock { state -> (
                CurrentValueSubject<ProgressEnvelope?, Never>,
                ProgressEnvelope,
            )? in
                guard !state.isFinished, !state.isCancelled else {
                    return nil
                }

                state.generation += 1
                let envelope = ProgressEnvelope(generation: state.generation, progress: progress)
                return (state.subject, envelope)
            }
            guard let (subject, envelope) = delivery else {
                return nil
            }

            subject.send(envelope)
            return envelope.generation
        }
    }

    func finish() {
        deliveryLock.withLock {
            let subject = state.withLock { state -> CurrentValueSubject<ProgressEnvelope?, Never>? in
                guard !state.isFinished, !state.isCancelled else {
                    return nil
                }

                state.isFinished = true
                return state.subject
            }
            subject?.send(completion: .finished)
        }
    }

    func cancel() {
        deliveryLock.withLock {
            state.withLock { $0.isCancelled = true }
        }
    }
}

private func makeProgressPublisher(
    for task: NetworkTask<some Sendable>,
) -> AnyPublisher<NetworkProgress, Never> {
    let relay = ProgressRelay()
    let (acknowledgements, acknowledgementContinuation) = AsyncStream<UInt64>.makeStream(
        bufferingPolicy: .bufferingNewest(1),
    )
    let observation = CombineObservation()
    let publisher = relay.publisher { generation in
        acknowledgementContinuation.yield(generation)
    }

    let observer = Task { [task, relay, acknowledgements] in
        var iterator = task.progress.makeAsyncIterator()
        var latestGeneration: UInt64?
        while let progress = await iterator.next() {
            guard !Task.isCancelled else {
                return
            }

            latestGeneration = relay.send(progress)
        }

        guard !Task.isCancelled else {
            return
        }

        if let latestGeneration {
            var acknowledgementIterator = acknowledgements.makeAsyncIterator()
            while let acknowledgedGeneration = await acknowledgementIterator.next() {
                if acknowledgedGeneration >= latestGeneration {
                    break
                }
            }
        }

        guard !Task.isCancelled else {
            return
        }

        relay.finish()
    }
    observation.install(observer)

    return publisher
        .handleEvents(receiveCancel: {
            relay.cancel()
            acknowledgementContinuation.finish()
            observation.cancel()
        })
        .eraseToAnyPublisher()
}
#endif
