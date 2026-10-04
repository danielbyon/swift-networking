//
//  CombineBridgeTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

#if canImport(Combine)
import Combine

@Suite(.serialized)
struct CombineBridgeTests {
    @Test("Client publisher is cold and creates one execution per subscription")
    func clientPublisherCreatesOneExecutionPerSubscription() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(Data([0x2a]), HTTPResponse(status: .init(code: 200))),
            gated: false,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let request = try makeCombineBridgeRequest()
        let publisher = client.publisher(for: request)

        #expect(await transport.executionCount == 0)

        let firstCapture = CombineBridgeCapture<Response<Data>>()
        let secondCapture = CombineBridgeCapture<Response<Data>>()
        let firstCancellable = record(publisher, into: firstCapture)
        let secondCancellable = record(publisher, into: secondCapture)

        var firstIterator = firstCapture.stream.makeAsyncIterator()
        var secondIterator = secondCapture.stream.makeAsyncIterator()
        let firstOptionalEvent = await firstIterator.next()
        let secondOptionalEvent = await secondIterator.next()
        let firstEvent = try #require(firstOptionalEvent)
        let secondEvent = try #require(secondOptionalEvent)
        guard case let .value(firstResponse) = firstEvent,
              case let .value(secondResponse) = secondEvent
        else {
            Issue.record("Expected both subscriptions to receive a response")
            return
        }

        #expect(firstResponse.requestID != secondResponse.requestID)
        #expect(await transport.executionCount == 2)
        let firstOptionalCompletion = await firstIterator.next()
        let secondOptionalCompletion = await secondIterator.next()
        let firstCompletion = try #require(firstOptionalCompletion)
        let secondCompletion = try #require(secondOptionalCompletion)
        #expect(firstCompletion.isFinished)
        #expect(secondCompletion.isFinished)
        withExtendedLifetime((firstCancellable, secondCancellable)) {}
    }

    @Test("Client publisher cancellation cancels its owned request")
    func clientPublisherCancellationCancelsOwnedRequest() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(Data([0x2a]), HTTPResponse(status: .init(code: 200))),
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let subscriber = ManualDemandSubscriber<Response<Data>, Error>()

        let request = try makeCombineBridgeRequest()
        client.publisher(for: request).receive(subscriber: subscriber)
        subscriber.request(.unlimited)
        await transport.waitForStart()

        subscriber.cancel()
        await transport.waitForCancellation()

        #expect(await transport.executionCount == 1)
        #expect(await transport.cancellationCount == 1)
        #expect(subscriber.values.isEmpty)
    }

    @Test("Client publisher handles cancellation during subscription setup")
    func clientPublisherCancellationDuringSubscriptionSetupIsSafe() throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(Data([0x2a]), HTTPResponse(status: .init(code: 200))),
            gated: false,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let subscriber = ManualDemandSubscriber<Response<Data>, Error>(cancelOnSubscription: true)

        let request = try makeCombineBridgeRequest()
        client.publisher(for: request).receive(subscriber: subscriber)

        #expect(subscriber.values.isEmpty)
        if case .some = subscriber.completion {
            Issue.record("Cancellation during subscription setup must not deliver a completion")
        }
    }

    @Test("Value publisher subscribers share one task and can cancel independently")
    func valuePublisherSharesTaskAndReplaysLateSuccess() async throws {
        let transport = ControlledNetworkTransport(
            outcome: .success(Data([0x2a]), HTTPResponse(status: .init(code: 200))),
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = try client.task(for: makeCombineBridgeRequest())
        let cancelledSubscriber = ManualDemandSubscriber<Response<Data>, Error>()
        let firstSubscriber = ManualDemandSubscriber<Response<Data>, Error>()
        let secondSubscriber = ManualDemandSubscriber<Response<Data>, Error>()
        task.valuePublisher.receive(subscriber: cancelledSubscriber)
        task.valuePublisher.receive(subscriber: firstSubscriber)
        task.valuePublisher.receive(subscriber: secondSubscriber)
        firstSubscriber.request(.unlimited)
        secondSubscriber.request(.unlimited)

        await transport.waitForStart()
        cancelledSubscriber.cancel()
        await transport.releaseSuccess()

        var firstEvents = firstSubscriber.events.makeAsyncIterator()
        var secondEvents = secondSubscriber.events.makeAsyncIterator()
        let optionalFirstResponseEvent = await firstEvents.next()
        let optionalSecondResponseEvent = await secondEvents.next()
        let firstResponseEvent = try #require(optionalFirstResponseEvent)
        let secondResponseEvent = try #require(optionalSecondResponseEvent)
        guard case let .value(firstResponse) = firstResponseEvent,
              case let .value(secondResponse) = secondResponseEvent
        else {
            Issue.record("Expected concurrent value subscribers to receive a response")
            return
        }

        #expect(firstResponse.requestID == task.requestID)
        #expect(secondResponse.requestID == firstResponse.requestID)
        #expect(firstResponse.value == Data([0x2a]))
        let optionalFirstCompletionEvent = await firstEvents.next()
        let optionalSecondCompletionEvent = await secondEvents.next()
        let firstCompletionEvent = try #require(optionalFirstCompletionEvent)
        let secondCompletionEvent = try #require(optionalSecondCompletionEvent)
        #expect(firstCompletionEvent.isFinished)
        #expect(secondCompletionEvent.isFinished)

        let lateSubscriber = ManualDemandSubscriber<Response<Data>, Error>()
        task.valuePublisher.receive(subscriber: lateSubscriber)
        lateSubscriber.request(.unlimited)
        var lateEvents = lateSubscriber.events.makeAsyncIterator()
        let optionalLateResponseEvent = await lateEvents.next()
        let lateResponseEvent = try #require(optionalLateResponseEvent)
        guard case let .value(lateResponse) = lateResponseEvent else {
            Issue.record("Expected a late subscriber to receive the stored response")
            return
        }

        #expect(lateResponse.requestID == firstResponse.requestID)
        let optionalLateCompletionEvent = await lateEvents.next()
        let lateCompletionEvent = try #require(optionalLateCompletionEvent)
        #expect(lateCompletionEvent.isFinished)
        #expect(cancelledSubscriber.values.isEmpty)
        #expect(await transport.executionCount == 1)
        #expect(await transport.cancellationCount == 0)

        let reentrantSubscriber = ManualDemandSubscriber<Response<Data>, Error>(cancelOnValue: true)
        task.valuePublisher.receive(subscriber: reentrantSubscriber)
        reentrantSubscriber.request(.unlimited)
        var reentrantEvents = reentrantSubscriber.events.makeAsyncIterator()
        let optionalReentrantEvent = await reentrantEvents.next()
        let reentrantEvent = try #require(optionalReentrantEvent)
        guard case let .value(reentrantResponse) = reentrantEvent else {
            Issue.record("Expected a reentrant subscriber to receive the stored response")
            return
        }

        #expect(reentrantResponse.requestID == firstResponse.requestID)
        #expect(await transport.cancellationCount == 0)
    }

    @Test("Late value publisher delivers failure without demand")
    func valuePublisherDeliversLateFailureWithoutDemand() async throws {
        let transport = ControlledNetworkTransport(outcome: .failure(.expectedFailure), gated: false)
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = try client.task(for: makeCombineBridgeRequest())

        do {
            _ = try await task.value
            Issue.record("Expected the shared task to fail")
        } catch is ControlledTransportError {}

        let subscriber = ManualDemandSubscriber<Response<Data>, Error>()
        task.valuePublisher.receive(subscriber: subscriber)
        var events = subscriber.events.makeAsyncIterator()
        let optionalFailureEvent = await events.next()
        let failureEvent = try #require(optionalFailureEvent)
        guard case let .failure(errorDescription) = failureEvent else {
            Issue.record("Expected failure completion without requesting demand")
            return
        }

        #expect(errorDescription.contains("ControlledTransportError"))
        #expect(subscriber.values.isEmpty)
        #expect(await transport.executionCount == 1)
    }

    @Test("Failed task finishes a demand-starved progress subscription")
    func failedTaskFinishesDemandStarvedProgressSubscription() async throws {
        let requestID = RequestID(rawValue: UUID())
        let initialProgressGate = CombineAsyncGate()
        let failureGate = CombineAsyncGate()
        let (initialReady, initialReadyContinuation) = AsyncStream<Bool>.makeStream()
        let (pendingReady, pendingReadyContinuation) = AsyncStream<Bool>.makeStream()
        let task = NetworkTask<Data>(requestID: requestID) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 10))
            progress.updateUpload(bytesSent: 1, expectedBytesToSend: 10)
            initialReadyContinuation.yield(true)
            await initialProgressGate.wait()

            progress.updateUpload(bytesSent: 2, expectedBytesToSend: 10)
            pendingReadyContinuation.yield(true)
            await failureGate.wait()
            throw ControlledTransportError.expectedFailure
        }

        var initialProgressIterator = initialReady.makeAsyncIterator()
        #expect(await initialProgressIterator.next() == true)

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: subscriber)
        subscriber.request(.max(1))
        var events = subscriber.events.makeAsyncIterator()
        let optionalInitialEvent = await events.next()
        let initialEvent = try #require(optionalInitialEvent)
        guard case let .value(initialProgress) = initialEvent else {
            Issue.record("Expected active progress before the failure")
            return
        }

        #expect(!initialProgress.isComplete)

        await initialProgressGate.open()
        var pendingProgressIterator = pendingReady.makeAsyncIterator()
        #expect(await pendingProgressIterator.next() == true)
        for _ in 0 ..< 32 {
            await Task.yield()
        }
        await failureGate.open()

        do {
            _ = try await task.value
            Issue.record("Expected the shared task to fail")
        } catch is ControlledTransportError {}

        await yieldUntilProgressCompletion(of: subscriber)
        let completion = try #require(subscriber.completion)
        #expect(completion.isFinished)
        #expect(subscriber.values.count == 1)
        #expect(subscriber.values.first?.isComplete == false)
        let finishEvent = try #require(await events.next())
        #expect(finishEvent.isFinished)
    }

    #if DEBUG
    @Test("Successful terminal progress waits for resumed demand")
    func successfulTerminalProgressWaitsForResumedDemand() async throws {
        let requestID = RequestID(rawValue: UUID())
        let response = Response(
            value: Data([0x2a]),
            httpResponse: HTTPResponse(status: .init(code: 200)),
            requestID: requestID,
        )
        let completionGate = CombineAsyncGate()
        let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
        let task = NetworkTask<Data>(requestID: requestID) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 10))
            progress.updateUpload(bytesSent: 5, expectedBytesToSend: 10)
            startedContinuation.yield(true)
            await completionGate.wait()
            return response
        }
        var startedIterator = started.makeAsyncIterator()
        #expect(await startedIterator.next() == true)

        let (terminalBuffered, terminalBufferedContinuation) = AsyncStream<Bool>.makeStream()
        let publisher = makeProgressPublisher(
            for: task,
            onPendingTerminalProgress: { sequenceFinished in
                _ = terminalBufferedContinuation.yield(sequenceFinished)
            },
        )
        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        publisher.receive(subscriber: subscriber)
        subscriber.request(.max(1))
        var events = subscriber.events.makeAsyncIterator()
        let optionalActiveEvent = await events.next()
        let activeEvent = try #require(optionalActiveEvent)
        guard case let .value(activeProgress) = activeEvent else {
            Issue.record("Expected active progress before successful completion")
            return
        }

        #expect(!activeProgress.isComplete)

        await completionGate.open()
        let result = try await task.value
        #expect(result.requestID == requestID)

        var terminalBufferedIterator = terminalBuffered.makeAsyncIterator()
        #expect(await terminalBufferedIterator.next() == false)
        #expect(await terminalBufferedIterator.next() == true)
        #expect(subscriber.values.count == 1)
        #expect(subscriber.completion == nil)

        subscriber.request(.max(1))
        let optionalTerminalEvent = await events.next()
        let terminalEvent = try #require(optionalTerminalEvent)
        guard case let .value(terminalProgress) = terminalEvent else {
            Issue.record("Expected pending successful terminal progress after demand resumed")
            return
        }

        #expect(terminalProgress.isComplete)

        let optionalFinishEvent = await events.next()
        let finishEvent = try #require(optionalFinishEvent)
        #expect(finishEvent.isFinished)
    }
    #endif

    @Test("Progress publisher honors additional demand returned by the subscriber")
    func progressPublisherHonorsAdditionalDemandReturnedBySubscriber() async throws {
        let firstProgressGate = CombineAsyncGate()
        let failureGate = CombineAsyncGate()
        let (firstProgressReady, firstProgressReadyContinuation) = AsyncStream<Bool>.makeStream()
        let (secondProgressReady, secondProgressReadyContinuation) = AsyncStream<Bool>.makeStream()
        let task = NetworkTask<Data>(requestID: RequestID(rawValue: UUID())) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 10))
            progress.updateUpload(bytesSent: 1, expectedBytesToSend: 10)
            firstProgressReadyContinuation.yield(true)
            await firstProgressGate.wait()

            progress.updateUpload(bytesSent: 2, expectedBytesToSend: 10)
            secondProgressReadyContinuation.yield(true)
            await failureGate.wait()
            throw ControlledTransportError.expectedFailure
        }
        var firstProgressIterator = firstProgressReady.makeAsyncIterator()
        #expect(await firstProgressIterator.next() == true)

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>(
            additionalDemandOnFirstValue: .max(1),
        )
        task.progressPublisher.receive(subscriber: subscriber)
        subscriber.request(.max(1))
        var events = subscriber.events.makeAsyncIterator()
        let firstEvent = try #require(await events.next())
        guard case let .value(firstProgress) = firstEvent else {
            Issue.record("Expected the first active progress state")
            return
        }

        #expect(firstProgress.bytesSent == 1)

        await firstProgressGate.open()
        var secondProgressIterator = secondProgressReady.makeAsyncIterator()
        #expect(await secondProgressIterator.next() == true)
        let secondEvent = try #require(await events.next())
        guard case let .value(secondProgress) = secondEvent else {
            Issue.record("Expected additional demand to deliver the next progress state")
            return
        }

        #expect(secondProgress.bytesSent == 2)

        await failureGate.open()
        do {
            _ = try await task.value
            Issue.record("Expected the shared task to fail")
        } catch is ControlledTransportError {}

        let finishEvent = try #require(await events.next())
        #expect(finishEvent.isFinished)
        #expect(subscriber.values.count == 2)
    }

    @Test("Progress publisher honors demand and replays the latest successful state")
    func progressPublisherHonorsDemandAndReplaysLatestSuccessfulState() async throws {
        let requestID = RequestID(rawValue: UUID())
        let response = Response(
            value: Data([0x2a]),
            httpResponse: HTTPResponse(status: .init(code: 200)),
            requestID: requestID,
        )
        let completionGate = CombineAsyncGate()
        let (updates, updateContinuation) = AsyncStream<Bool>.makeStream()
        let task = NetworkTask<Data>(requestID: requestID) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 100))
            progress.updateUpload(bytesSent: 80, expectedBytesToSend: 100)
            #expect(progress.startAttempt(attemptNumber: 2, expectedBytesToSend: 100))
            progress.updateUpload(bytesSent: 20, expectedBytesToSend: 100)
            updateContinuation.yield(true)
            await completionGate.wait()
            return response
        }
        var updateIterator = updates.makeAsyncIterator()
        let optionalUpdate = await updateIterator.next()
        #expect(optionalUpdate == true)

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: subscriber)
        var events = subscriber.events.makeAsyncIterator()
        #expect(subscriber.values.isEmpty)

        subscriber.request(.max(1))
        let optionalLatestEvent = await events.next()
        let latestEvent = try #require(optionalLatestEvent)
        guard case let .value(latestProgress) = latestEvent else {
            Issue.record("Expected the latest active progress state")
            return
        }

        #expect(latestProgress.attemptNumber == 2)
        #expect(latestProgress.bytesSent == 20)
        #expect(!latestProgress.isComplete)

        await completionGate.open()
        let result = try await task.value
        #expect(result.requestID == requestID)
        #expect(subscriber.values.count == 1)

        subscriber.request(.max(1))
        let optionalTerminalEvent = await events.next()
        let terminalEvent = try #require(optionalTerminalEvent)
        guard case let .value(terminalProgress) = terminalEvent else {
            Issue.record("Expected successful terminal progress before completion")
            return
        }

        #expect(terminalProgress.isComplete)
        let optionalCompletionEvent = await events.next()
        let completionEvent = try #require(optionalCompletionEvent)
        #expect(completionEvent.isFinished)
        #expect(subscriber.completion?.isFinished == true)

        let lateSubscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: lateSubscriber)
        lateSubscriber.request(.max(1))
        var lateEvents = lateSubscriber.events.makeAsyncIterator()
        let optionalLateTerminalEvent = await lateEvents.next()
        let lateTerminalEvent = try #require(optionalLateTerminalEvent)
        guard case let .value(lateTerminalProgress) = lateTerminalEvent else {
            Issue.record("Expected a late progress subscriber to replay terminal progress")
            return
        }

        #expect(lateTerminalProgress.isComplete)
        let optionalLateCompletionEvent = await lateEvents.next()
        let lateCompletionEvent = try #require(optionalLateCompletionEvent)
        #expect(lateCompletionEvent.isFinished)
    }

    @Test("Failed progress publisher finishes without successful terminal progress")
    func failedProgressPublisherFinishesWithoutTerminalSuccess() async throws {
        let task = NetworkTask<Data>(requestID: RequestID(rawValue: UUID())) { _ in
            throw ControlledTransportError.expectedFailure
        }
        do {
            _ = try await task.value
            Issue.record("Expected the shared task to fail")
        } catch is ControlledTransportError {}

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: subscriber)
        var events = subscriber.events.makeAsyncIterator()
        let optionalCompletion = await events.next()
        let completion = try #require(optionalCompletion)
        #expect(completion.isFinished)
        #expect(subscriber.values.isEmpty)
    }

    @Test("Shared task cancellation finishes progress without terminal success")
    func sharedTaskCancellationFinishesProgressWithoutTerminalSuccess() async throws {
        let requestID = RequestID(rawValue: UUID())
        let response = Response(
            value: Data([0x2a]),
            httpResponse: HTTPResponse(status: .init(code: 200)),
            requestID: requestID,
        )
        let completionGate = CombineAsyncGate()
        let task = NetworkTask<Data>(requestID: requestID) { _ in
            await completionGate.wait()
            return response
        }

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: subscriber)
        subscriber.request(.unlimited)
        var events = subscriber.events.makeAsyncIterator()
        let optionalProgressEvent = await events.next()
        let progressEvent = try #require(optionalProgressEvent)
        guard case let .value(activeProgress) = progressEvent else {
            Issue.record("Expected active progress before shared cancellation")
            return
        }

        #expect(!activeProgress.isComplete)

        task.cancel()
        await completionGate.open()
        do {
            _ = try await task.value
            Issue.record("Expected NetworkTask.cancel() to cancel the shared value")
        } catch is CancellationError {}

        let optionalFinishEvent = await events.next()
        let finishEvent = try #require(optionalFinishEvent)
        #expect(finishEvent.isFinished)
        #expect(subscriber.completion?.isFinished == true)
        #expect(subscriber.values.count == 1)
    }

    @Test("Shared cancellation finishes a demand-starved progress subscription")
    func sharedCancellationFinishesDemandStarvedProgressSubscription() async throws {
        let requestID = RequestID(rawValue: UUID())
        let response = Response(
            value: Data([0x2a]),
            httpResponse: HTTPResponse(status: .init(code: 200)),
            requestID: requestID,
        )
        let initialProgressGate = CombineAsyncGate()
        let completionGate = CombineAsyncGate()
        let (initialReady, initialReadyContinuation) = AsyncStream<Bool>.makeStream()
        let (pendingReady, pendingReadyContinuation) = AsyncStream<Bool>.makeStream()
        let task = NetworkTask<Data>(requestID: requestID) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 10))
            progress.updateUpload(bytesSent: 1, expectedBytesToSend: 10)
            initialReadyContinuation.yield(true)
            await initialProgressGate.wait()

            progress.updateUpload(bytesSent: 2, expectedBytesToSend: 10)
            pendingReadyContinuation.yield(true)
            await completionGate.wait()
            return response
        }

        var initialProgressIterator = initialReady.makeAsyncIterator()
        #expect(await initialProgressIterator.next() == true)

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>()
        task.progressPublisher.receive(subscriber: subscriber)
        subscriber.request(.max(1))
        var events = subscriber.events.makeAsyncIterator()
        let initialEvent = try #require(await events.next())
        guard case let .value(initialProgress) = initialEvent else {
            Issue.record("Expected active progress before shared cancellation")
            return
        }

        #expect(!initialProgress.isComplete)

        await initialProgressGate.open()
        var pendingProgressIterator = pendingReady.makeAsyncIterator()
        #expect(await pendingProgressIterator.next() == true)
        for _ in 0 ..< 32 {
            await Task.yield()
        }

        task.cancel()
        await completionGate.open()
        do {
            _ = try await task.value
            Issue.record("Expected NetworkTask.cancel() to cancel the shared value")
        } catch is CancellationError {}

        await yieldUntilProgressCompletion(of: subscriber)
        let completion = try #require(subscriber.completion)
        #expect(completion.isFinished)
        #expect(subscriber.values.count == 1)
        #expect(subscriber.values.first?.isComplete == false)
        let finishEvent = try #require(await events.next())
        #expect(finishEvent.isFinished)
    }

    @Test("Cancelling a progress subscriber leaves the shared task running")
    func cancellingProgressSubscriberLeavesTaskRunning() async throws {
        let requestID = RequestID(rawValue: UUID())
        let response = Response(
            value: Data([0x2a]),
            httpResponse: HTTPResponse(status: .init(code: 200)),
            requestID: requestID,
        )
        let completionGate = CombineAsyncGate()
        let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
        let cancellationCount = Mutex(0)
        let task = NetworkTask<Data>(
            requestID: requestID,
            onCancelled: { cancellationCount.withLock { $0 += 1 } },
        ) { progress in
            #expect(progress.startAttempt(attemptNumber: 1, expectedBytesToSend: 10))
            progress.updateUpload(bytesSent: 5, expectedBytesToSend: 10)
            startedContinuation.yield(true)
            await completionGate.wait()
            return response
        }
        var startedIterator = started.makeAsyncIterator()
        let optionalStart = await startedIterator.next()
        #expect(optionalStart == true)

        let subscriber = ManualDemandSubscriber<NetworkProgress, Never>(cancelOnValue: true)
        task.progressPublisher.receive(subscriber: subscriber)
        subscriber.request(.unlimited)
        var events = subscriber.events.makeAsyncIterator()
        let optionalReceivedEvent = await events.next()
        let receivedEvent = try #require(optionalReceivedEvent)
        guard case .value = receivedEvent else {
            Issue.record("Expected progress before cancelling its observation")
            return
        }

        await completionGate.open()
        let result = try await task.value
        #expect(result.requestID == requestID)
        #expect(cancellationCount.withLock { $0 } == 0)
    }

    @Test("Value publisher cancellation racing with completion never delivers afterward")
    func valuePublisherCancellationRacesWithCompletion() async throws {
        for _ in 0 ..< 8 {
            let requestID = RequestID(rawValue: UUID())
            let response = Response(
                value: Data([0x2a]),
                httpResponse: HTTPResponse(status: .init(code: 200)),
                requestID: requestID,
            )
            let completionGate = CombineAsyncGate()
            let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
            let cancellationCount = Mutex(0)
            let task = NetworkTask<Data>(
                requestID: requestID,
                onCancelled: { cancellationCount.withLock { $0 += 1 } },
            ) { _ in
                startedContinuation.yield(true)
                await completionGate.wait()
                return response
            }
            var startedIterator = started.makeAsyncIterator()
            let optionalStart = await startedIterator.next()
            #expect(optionalStart == true)

            let deliveryState = CombineDeliveryState()
            let cancellationHarness = ValuePublisherCancellationHarness(deliveryState: deliveryState)
            await cancellationHarness.subscribe(to: task)

            let barrier = CombineRaceBarrier(participantCount: 2)
            let cancellation = Task {
                await barrier.arrive()
                await cancellationHarness.cancel()
            }
            let completion = Task {
                await barrier.arrive()
                await completionGate.open()
            }
            await cancellation.value
            await completion.value

            let result = try await task.value
            #expect(result.requestID == requestID)
            #expect(deliveryState.postCancellationDeliveries == 0)
            #expect(cancellationCount.withLock { $0 } == 0)
        }
    }
}

private enum CombineBridgeEvent<Output: Sendable>: Sendable {
    case value(Output)
    case finished
    case failure(String)

    var isFinished: Bool {
        if case .finished = self {
            return true
        }
        return false
    }
}

private struct CombineBridgeCapture<Output: Sendable>: Sendable {
    let stream: AsyncStream<CombineBridgeEvent<Output>>
    let continuation: AsyncStream<CombineBridgeEvent<Output>>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }
}

private func record<Output: Sendable>(
    _ publisher: AnyPublisher<Output, Error>,
    into capture: CombineBridgeCapture<Output>,
) -> AnyCancellable {
    publisher.sink { completion in
        switch completion {
        case .finished:
            capture.continuation.yield(.finished)
        case let .failure(error):
            capture.continuation.yield(.failure(String(reflecting: error)))
        }
    } receiveValue: { value in
        capture.continuation.yield(.value(value))
    }
}

private enum ManualDemandEvent<Output: Sendable>: Sendable {
    case value(Output)
    case finished
    case failure(String)

    var isFinished: Bool {
        if case .finished = self {
            return true
        }
        return false
    }
}

private final class ManualDemandSubscriber<Output: Sendable, FailureType: Error>: Subscriber {
    typealias Input = Output
    typealias Failure = FailureType

    private let stateLock = NSRecursiveLock()
    private let continuation: AsyncStream<ManualDemandEvent<Output>>.Continuation
    private let cancelOnSubscription: Bool
    private let cancelOnValue: Bool
    private var additionalDemandOnFirstValue: Subscribers.Demand
    let events: AsyncStream<ManualDemandEvent<Output>>
    private var subscription: (any Subscription)?
    private var receivedValues: [Output] = []
    private var recordedCompletion: ManualDemandEvent<Output>?

    init(
        cancelOnSubscription: Bool = false,
        cancelOnValue: Bool = false,
        additionalDemandOnFirstValue: Subscribers.Demand = .none,
    ) {
        (events, continuation) = AsyncStream.makeStream()
        self.cancelOnSubscription = cancelOnSubscription
        self.cancelOnValue = cancelOnValue
        self.additionalDemandOnFirstValue = additionalDemandOnFirstValue
    }

    var values: [Output] {
        stateLock.withLock { receivedValues }
    }

    var completion: ManualDemandEvent<Output>? {
        stateLock.withLock { recordedCompletion }
    }

    func receive(subscription newSubscription: any Subscription) {
        stateLock.withLock { subscription = newSubscription }
        if cancelOnSubscription {
            newSubscription.cancel()
        }
    }

    func receive(_ input: Output) -> Subscribers.Demand {
        let (subscriptionToCancel, additionalDemand) = stateLock.withLock { () -> (
            (any Subscription)?,
            Subscribers.Demand,
        ) in
            receivedValues.append(input)
            let additionalDemand = additionalDemandOnFirstValue
            additionalDemandOnFirstValue = .none
            if cancelOnValue {
                return (subscription, additionalDemand)
            }
            return (nil, additionalDemand)
        }
        continuation.yield(.value(input))
        subscriptionToCancel?.cancel()
        return additionalDemand
    }

    func receive(completion: Subscribers.Completion<FailureType>) {
        let event =
            switch completion {
            case .finished:
                ManualDemandEvent<Output>.finished
            case let .failure(error):
                ManualDemandEvent<Output>.failure(String(reflecting: error))
            }
        stateLock.withLock { recordedCompletion = event }
        continuation.yield(event)
        continuation.finish()
    }

    func request(_ demand: Subscribers.Demand) {
        let currentSubscription = stateLock.withLock { subscription }
        currentSubscription?.request(demand)
    }

    func cancel() {
        let currentSubscription = stateLock.withLock { () -> (any Subscription)? in
            defer { subscription = nil }
            return subscription
        }
        currentSubscription?.cancel()
    }
}

private actor CombineAsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { waiter in
            continuation = waiter
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CombineRaceBarrier {
    private let participantCount: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arrive() async {
        arrivals += 1
        guard arrivals < participantCount else {
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuations.append($0) }
    }
}

private final class CombineDeliveryState: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var postCancellationDeliveries = 0
    }

    private let state = Mutex(State())

    var postCancellationDeliveries: Int {
        state.withLock { $0.postCancellationDeliveries }
    }

    func recordDelivery() {
        state.withLock { state in
            if state.isCancelled {
                state.postCancellationDeliveries += 1
            }
        }
    }

    func markCancelled() {
        state.withLock { $0.isCancelled = true }
    }
}

private actor ValuePublisherCancellationHarness {
    private var cancellable: AnyCancellable?
    private let deliveryState: CombineDeliveryState

    init(deliveryState: CombineDeliveryState) {
        self.deliveryState = deliveryState
    }

    func subscribe(to task: NetworkTask<Data>) {
        let observedDeliveryState = deliveryState
        cancellable = task.valuePublisher.sink { _ in
        } receiveValue: { _ in
            observedDeliveryState.recordDelivery()
        }
    }

    func cancel() {
        cancellable?.cancel()
        cancellable = nil
        deliveryState.markCancelled()
    }
}

private func yieldUntilProgressCompletion(
    of subscriber: ManualDemandSubscriber<NetworkProgress, Never>,
) async {
    for _ in 0 ..< 512 {
        if subscriber.completion != nil {
            return
        }
        await Task.yield()
    }
}

private func makeCombineBridgeRequest(
    response: ResponseDecoding<Data> = .data,
) throws -> Request<Data> {
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/combine-bridge"))),
        response: response,
    )
    return Request(endpoint: endpoint)
}
#endif
