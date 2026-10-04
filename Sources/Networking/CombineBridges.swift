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

/// Creates one independent asynchronous progress observation for each Combine subscriber.
private struct TaskProgressPublisher<Value: Sendable>: Publisher {
    typealias Output = NetworkProgress
    typealias Failure = Never

    let task: NetworkTask<Value>
    let onPendingTerminalProgress: @Sendable (_ sequenceFinished: Bool) -> Void

    func receive<Downstream: Subscriber>(subscriber: Downstream)
        where Downstream.Input == NetworkProgress, Downstream.Failure == Never {
        let mailbox = ProgressMailbox()
        let subscription = TaskProgressSubscription(
            downstream: subscriber,
            mailbox: mailbox,
        )
        subscriber.receive(subscription: subscription)
        subscription.startObserving(
            task: task,
            onPendingTerminalProgress: onPendingTerminalProgress,
        )
    }
}

/// Stores demand and the single latest unseen progress state for one subscriber.
///
/// The subject forwards values only after this mailbox has consumed downstream demand. It is not
/// used as a backpressure buffer; the per-subscriber state below owns that contract.
private enum ProgressLifecycle {
    case observing
    case successfulTerminalPending(sequenceFinished: Bool)
    case successfulTerminalDelivered(sequenceFinished: Bool)
    case finished
    case cancelled

    var isStopped: Bool {
        switch self {
        case .finished,
             .cancelled:
            true
        case .observing,
             .successfulTerminalPending,
             .successfulTerminalDelivered:
            false
        }
    }
}

/// Owns the per-subscriber backpressure state and forwards admitted values to its Combine adapter.
///
/// The private passthrough subject carries only values for which this mailbox has already consumed
/// demand. It does not cache progress; `pendingProgress` is the sole latest-state buffer.
private final class ProgressMailbox: Sendable {
    private enum DemandBalance: Sendable {
        case finite(Int)
        case unlimited

        mutating func add(_ demand: Subscribers.Demand) {
            guard let value = demand.max else {
                self = .unlimited
                return
            }
            guard value > 0 else {
                return
            }

            switch self {
            case .unlimited:
                break
            case let .finite(current):
                let (sum, overflow) = current.addingReportingOverflow(value)
                self = overflow ? .unlimited : .finite(sum)
            }
        }

        mutating func consumeOne() -> Bool {
            switch self {
            case .unlimited:
                return true
            case let .finite(value) where value > 0:
                self = .finite(value - 1)
                return true
            case .finite:
                return false
            }
        }
    }

    private struct State {
        let subject = PassthroughSubject<NetworkProgress, Never>()
        var demand = DemandBalance.finite(0)
        var pendingProgress: NetworkProgress?
        var lifecycle = ProgressLifecycle.observing
    }

    private let deliveryLock = NSRecursiveLock()
    private let state = Mutex(State())

    var publisher: AnyPublisher<NetworkProgress, Never> {
        state.withLock { $0.subject.eraseToAnyPublisher() }
    }

    func withDeliveryLock(_ operation: () -> Void) {
        deliveryLock.withLock(operation)
    }

    var isCancelled: Bool {
        state.withLock {
            if case .cancelled = $0.lifecycle {
                true
            } else {
                false
            }
        }
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else {
            return
        }

        deliveryLock.withLock {
            let pending = state.withLock { state -> NetworkProgress? in
                guard !state.lifecycle.isStopped else {
                    return nil
                }

                state.demand.add(demand)
                guard let pending = state.pendingProgress, state.demand.consumeOne() else {
                    return nil
                }

                state.pendingProgress = nil
                return pending
            }
            if let pending {
                emit(pending)
            }
        }
    }

    func receive(
        _ progress: NetworkProgress,
        onPendingTerminalProgress: @Sendable (_ sequenceFinished: Bool) -> Void,
    ) {
        deliveryLock.withLock {
            var progressToDeliver: NetworkProgress?
            var storedTerminal = false
            state.withLock { state in
                guard case .observing = state.lifecycle else {
                    return
                }

                if state.demand.consumeOne() {
                    progressToDeliver = progress
                } else {
                    state.pendingProgress = progress
                    if progress.isComplete {
                        state.lifecycle = .successfulTerminalPending(sequenceFinished: false)
                        storedTerminal = true
                    }
                }
            }

            if let progressToDeliver {
                emit(progressToDeliver)
            } else if storedTerminal {
                onPendingTerminalProgress(false)
            }
        }
    }

    func finish(
        finalProgress: NetworkProgress?,
        onPendingTerminalProgress: @Sendable (_ sequenceFinished: Bool) -> Void,
    ) {
        deliveryLock.withLock {
            var progressToDeliver: NetworkProgress?
            var shouldFinish = false
            var storedTerminal = false

            state.withLock { state in
                guard !state.lifecycle.isStopped else {
                    return
                }
                guard let terminalProgress = finalProgress, terminalProgress.isComplete else {
                    state.pendingProgress = nil
                    state.lifecycle = .finished
                    shouldFinish = true
                    return
                }

                switch state.lifecycle {
                case .observing:
                    state.lifecycle = .successfulTerminalPending(sequenceFinished: true)
                    if state.demand.consumeOne() {
                        state.pendingProgress = nil
                        progressToDeliver = terminalProgress
                    } else {
                        state.pendingProgress = terminalProgress
                        storedTerminal = true
                    }
                case .successfulTerminalPending:
                    state.lifecycle = .successfulTerminalPending(sequenceFinished: true)
                    if state.demand.consumeOne() {
                        state.pendingProgress = nil
                        progressToDeliver = terminalProgress
                    } else {
                        storedTerminal = true
                    }
                case .successfulTerminalDelivered:
                    state.lifecycle = .finished
                    shouldFinish = true
                case .finished,
                     .cancelled:
                    return
                }
            }

            if storedTerminal {
                onPendingTerminalProgress(true)
            }
            if let progressToDeliver {
                emit(progressToDeliver)
            } else if shouldFinish {
                sendFinished()
            }
        }
    }

    func cancel(_ cleanUp: () -> Void) {
        deliveryLock.withLock {
            state.withLock { state in
                state.lifecycle = .cancelled
                state.pendingProgress = nil
            }
            cleanUp()
        }
    }

    private func emit(_ progress: NetworkProgress) {
        let subject = state.withLock { state -> PassthroughSubject<NetworkProgress, Never>? in
            guard !state.lifecycle.isStopped else {
                return nil
            }

            return state.subject
        }
        guard let subject else {
            return
        }

        subject.send(progress)
        guard progress.isComplete else {
            return
        }

        let shouldFinish = state.withLock { state -> Bool in
            switch state.lifecycle {
            case .observing:
                state.lifecycle = .successfulTerminalDelivered(sequenceFinished: false)
                return false
            case .successfulTerminalPending(sequenceFinished: true):
                state.lifecycle = .finished
                return true
            case .successfulTerminalPending(sequenceFinished: false):
                state.lifecycle = .successfulTerminalDelivered(sequenceFinished: false)
                return false
            case .successfulTerminalDelivered,
                 .finished,
                 .cancelled:
                return false
            }
        }
        if shouldFinish {
            sendFinished()
        }
    }

    private func sendFinished() {
        let subject = state.withLock { state -> PassthroughSubject<NetworkProgress, Never>? in
            guard case .finished = state.lifecycle else {
                return nil
            }

            return state.subject
        }
        subject?.send(completion: .finished)
    }
}

/// Bridges one progress mailbox to a Combine subscriber and owns only its observation task.
private final class TaskProgressSubscription<Downstream: Subscriber>: Subscription
    where Downstream.Input == NetworkProgress, Downstream.Failure == Never {
    private let mailbox: ProgressMailbox
    private var downstream: Downstream?
    private var observation: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(downstream: Downstream, mailbox: ProgressMailbox) {
        self.downstream = downstream
        self.mailbox = mailbox
        cancellable = mailbox.publisher.sink(
            receiveCompletion: { [weak self] completion in
                self?.receive(completion: completion)
            },
            receiveValue: { [weak self] progress in
                self?.receive(progress)
            },
        )
    }

    func request(_ demand: Subscribers.Demand) {
        mailbox.request(demand)
    }

    func cancel() {
        mailbox.cancel {
            observation?.cancel()
            observation = nil
            cancellable?.cancel()
            cancellable = nil
            downstream = nil
        }
    }

    func startObserving(
        task: NetworkTask<some Sendable>,
        onPendingTerminalProgress: @escaping @Sendable (_ sequenceFinished: Bool) -> Void,
    ) {
        mailbox.withDeliveryLock {
            guard !mailbox.isCancelled else {
                return
            }

            observation = Task { [task, mailbox, onPendingTerminalProgress] in
                var iterator = task.progress.makeAsyncIterator()
                var finalProgress: NetworkProgress?
                while let progress = await iterator.next() {
                    guard !Task.isCancelled else {
                        return
                    }

                    finalProgress = progress
                    mailbox.receive(
                        progress,
                        onPendingTerminalProgress: onPendingTerminalProgress,
                    )
                }

                guard !Task.isCancelled else {
                    return
                }

                mailbox.finish(
                    finalProgress: finalProgress,
                    onPendingTerminalProgress: onPendingTerminalProgress,
                )
            }
        }
    }

    private func receive(_ progress: NetworkProgress) {
        mailbox.withDeliveryLock {
            guard let downstream else {
                return
            }

            mailbox.request(downstream.receive(progress))
        }
    }

    private func receive(completion: Subscribers.Completion<Never>) {
        mailbox.withDeliveryLock {
            guard let downstream else {
                return
            }

            self.downstream = nil
            observation = nil
            downstream.receive(completion: completion)
        }
    }
}

/// Creates a demand-aware publisher for one task's progress sequence.
///
/// - Parameters:
///   - task: The shared logical task whose progress is observed.
/// Creates a demand-aware publisher for one task's progress sequence.
private func makeProgressPublisher(
    for task: NetworkTask<some Sendable>,
) -> AnyPublisher<NetworkProgress, Never> {
    makeProgressPublisherImplementation(for: task, onPendingTerminalProgress: { _ in })
}

#if DEBUG
/// Creates a progress publisher with a synchronization hook for deterministic bridge tests.
///
/// - Parameters:
///   - task: The shared logical task whose progress is observed.
///   - onPendingTerminalProgress: Called after successful terminal progress is buffered at zero
///     demand, with whether the progress sequence has finished.
func makeProgressPublisher(
    for task: NetworkTask<some Sendable>,
    onPendingTerminalProgress: @escaping @Sendable (_ sequenceFinished: Bool) -> Void,
) -> AnyPublisher<NetworkProgress, Never> {
    makeProgressPublisherImplementation(
        for: task,
        onPendingTerminalProgress: onPendingTerminalProgress,
    )
}
#endif

private func makeProgressPublisherImplementation(
    for task: NetworkTask<some Sendable>,
    onPendingTerminalProgress: @escaping @Sendable (_ sequenceFinished: Bool) -> Void,
) -> AnyPublisher<NetworkProgress, Never> {
    TaskProgressPublisher(
        task: task,
        onPendingTerminalProgress: onPendingTerminalProgress,
    )
    .eraseToAnyPublisher()
}
#endif
