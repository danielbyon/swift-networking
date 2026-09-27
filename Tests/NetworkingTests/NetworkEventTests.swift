//
//  NetworkEventTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Dispatch
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Synchronization
import Testing
@testable import Networking

@Suite(.serialized)
struct NetworkEventTests {
    @Test("Successful executions deliver ordered lifecycle events to copied observer configuration")
    func successfulExecutionDeliversLifecycleEventsToEachObserver() async throws {
        let firstCapture = NetworkEventCapture()
        let secondCapture = NetworkEventCapture()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let configuration = NetworkClient.Configuration()
            .withEventObserver(firstCapture.observer)
            .withDefaultHeaders(HTTPFields())
            .withEventObserver(secondCapture.observer)
        let client = try NetworkClient(
            transport: ImmediateEventTransport(),
            configuration: configuration,
            retryTimingDependencies: RetryTimingDependencies(
                sleep: { _ in },
                now: { timestamp },
                randomUnit: { 0 },
            ),
        )
        let request = try makeEventRequest()

        let task = client.task(for: request)
        let response = try await task.value

        #expect(response.value == Data([0x2a]))
        let firstEvents = await firstCapture.eventsThroughTerminal()
        let secondEvents = await secondCapture.eventsThroughTerminal()
        let expectedKinds = ["requestStarted", "attemptStarted", "responseReceived", "requestCompleted"]
        #expect(firstEvents.map(\.kind) == expectedKinds)
        #expect(secondEvents.map(\.kind) == expectedKinds)
        #expect(firstEvents.allSatisfy { $0.timestamp == timestamp })
        #expect(firstEvents.allSatisfy { $0.trace == "event-context" })
        #expect(firstEvents.allSatisfy { $0.requestID == task.requestID })

        guard case let .requestStarted(started) = firstEvents[0] else {
            Issue.record("Expected requestStarted first")
            return
        }

        #expect(started.requestID == task.requestID)
        #expect(started.timestamp == timestamp)
        #expect(started.requestContext[EventTraceKey.self] == "event-context")

        guard case let .attemptStarted(attemptStarted) = firstEvents[1] else {
            Issue.record("Expected attemptStarted second")
            return
        }

        #expect(attemptStarted.requestID == task.requestID)
        #expect(attemptStarted.attemptNumber == 1)
        #expect(attemptStarted.request.method == .post)
        #expect(attemptStarted.timestamp == timestamp)

        guard case let .responseReceived(received) = firstEvents[2] else {
            Issue.record("Expected responseReceived third")
            return
        }

        #expect(received.httpResponse.status.code == 200)
        #expect(received.normalizedMetrics.duration == nil)
        #expect(received.rawTaskMetrics == nil)

        guard case let .requestCompleted(completed) = firstEvents[3] else {
            Issue.record("Expected requestCompleted last")
            return
        }

        #expect(completed.httpResponse.status.code == 200)
        #expect(completed.timestamp == timestamp)
    }

    @Test("Request start is submitted before immediate shared cancellation")
    func requestStartedPrecedesImmediateSharedCancellation() async throws {
        let capture = NetworkEventCapture()
        let transport = BlockingEventTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withEventObserver(capture.observer),
        )

        let task = try client.task(for: makeEventRequest())
        task.cancel()
        let events = await capture.eventsThroughTerminal()
        await transport.release()

        #expect(events.first?.kind == "requestStarted")
        #expect(events.last?.kind == "requestCancelled")
        #expect(events.filter(\.isTerminal).count == 1)
        #expect(events.last?.requestID == task.requestID)
    }

    @Test("Shared cancellation before URLSession start commit emits no attempt event")
    func cancellationBeforeURLSessionStartCommitEmitsNoAttemptStarted() async throws {
        let capture = NetworkEventCapture()
        let beforeStartGate = BlockingEventCallback()
        let decisions = TaskStartDecisionCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StartCommitURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
            beforeTaskStart: { beforeStartGate.pauseOnFirstCall() },
            afterTaskStartDecision: { didCommit in
                Task { await decisions.record(didCommit) }
            },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())
        defer { beforeStartGate.release() }

        await beforeStartGate.waitUntilBlocked()
        task.cancel()
        beforeStartGate.release()

        let didCommitStart = await decisions.next()
        let events = await capture.eventsThroughTerminal()

        #expect(didCommitStart == false)
        #expect(events.map(\.kind) == ["requestStarted", "requestCancelled"])
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test("A committed URLSession start publishes attemptStarted before shared cancellation")
    func committedURLSessionStartPublishesAttemptStartedBeforeCancellation() async throws {
        let capture = NetworkEventCapture()
        let afterDecisionGate = BlockingEventCallback()
        let decisions = TaskStartDecisionCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StartCommitURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
            afterTaskStartDecision: { didCommit in
                Task { await decisions.record(didCommit) }
                if didCommit {
                    afterDecisionGate.pauseOnFirstCall()
                }
            },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())
        defer { afterDecisionGate.release() }

        await afterDecisionGate.waitUntilBlocked()
        let didCommitStart = await decisions.next()
        task.cancel()
        let events = await capture.eventsThroughTerminal()

        #expect(didCommitStart)
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "requestCancelled"])
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test("Preflight failure follows request start and has no attempt events")
    func preflightFailureEmitsOnlyLogicalFailureEvents() async throws {
        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: ImmediateEventTransport(),
            configuration: .init().withEventObserver(capture.observer),
        )
        let endpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .relative(forInput: "witness") { ["items", $0] },
            response: .data,
        )
        let task = client.task(for: Request(endpoint: endpoint, input: "42"))

        do {
            _ = try await task.value
            Issue.record("Expected preflight to fail without a base URL")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .relativeRouteRequiresBaseURL)
        }

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "requestFailed"])
        #expect(events.last?.requestID == task.requestID)
    }

    @Test("Started transport failure emits attempt failure before logical failure")
    func startedTransportFailureEmitsAttemptFailure() async throws {
        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: ScriptedEventTransport([.failure(.transportFailure)]),
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())

        do {
            _ = try await task.value
            Issue.record("Expected transport failure")
        } catch is EventTransportError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "attemptFailed", "requestFailed"])
        guard case let .attemptFailed(failed) = events[2] else {
            Issue.record("Expected attemptFailed")
            return
        }

        #expect(failed.attemptNumber == 1)
        #expect(failed.rawTaskMetrics == nil)
    }

    @Test("A transport result marked not started emits no attempt events")
    func unstartedTransportResultHasNoAttemptEvents() async throws {
        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: UnstartedEventTransport(),
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())

        do {
            _ = try await task.value
            Issue.record("Expected an unstarted transport failure")
        } catch is EventTransportError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "requestFailed"])
    }

    @Test("A work-level CancellationError is failure unless shared cancellation wins")
    func independentCancellationErrorEmitsRequestFailure() async throws {
        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: StartedCancellationEventTransport(),
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())

        do {
            _ = try await task.value
            Issue.record("Expected the transport's independent CancellationError")
        } catch is CancellationError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "attemptFailed", "requestFailed"])
    }

    @Test("Response and transport retries publish their resolved delays before the next attempt")
    func retryEventsFollowResponseAndTransportFailures() async throws {
        let responseCapture = NetworkEventCapture()
        let responseClient = try NetworkClient(
            transport: ScriptedEventTransport([.response(status: 503), .response(status: 200)]),
            configuration: .init()
                .withEventObserver(responseCapture.observer)
                .withRetryPolicy(RetryPolicy { $0.maximumRetries = 1 }),
            retryTimingDependencies: RetryTimingDependencies(
                sleep: { _ in },
                now: { Date(timeIntervalSince1970: 10) },
                randomUnit: { 0 },
            ),
        )
        let responseTask = try responseClient.task(for: makeGetEventRequest())
        _ = try await responseTask.value
        let responseEvents = await responseCapture.eventsThroughTerminal()
        #expect(responseEvents.map(\.kind) == [
            "requestStarted",
            "attemptStarted",
            "responseReceived",
            "retryScheduled",
            "attemptStarted",
            "responseReceived",
            "requestCompleted",
        ])
        guard case let .retryScheduled(responseRetry) = responseEvents[3] else {
            Issue.record("Expected response-driven retryScheduled")
            return
        }

        #expect(responseRetry.attemptNumber == 1)
        #expect(responseRetry.httpResponse?.status.code == 503)
        #expect(responseRetry.delay == .zero)
        #expect(responseEvents.compactMap(\.attemptNumber) == [1, 1, 1, 2, 2])

        let errorCapture = NetworkEventCapture()
        let errorPolicy = RetryPolicy {
            $0.maximumRetries = 1
            $0.customDecision = { _ in .retry }
        }
        let errorClient = try NetworkClient(
            transport: ScriptedEventTransport([.failure(.transportFailure), .response(status: 200)]),
            configuration: .init().withEventObserver(errorCapture.observer).withRetryPolicy(errorPolicy),
            retryTimingDependencies: RetryTimingDependencies(
                sleep: { _ in },
                now: { Date(timeIntervalSince1970: 10) },
                randomUnit: { 0 },
            ),
        )
        _ = try await errorClient.task(for: makeGetEventRequest()).value
        let errorEvents = await errorCapture.eventsThroughTerminal()
        #expect(errorEvents.map(\.kind) == [
            "requestStarted",
            "attemptStarted",
            "attemptFailed",
            "retryScheduled",
            "attemptStarted",
            "responseReceived",
            "requestCompleted",
        ])
        guard case let .retryScheduled(errorRetry) = errorEvents[3] else {
            Issue.record("Expected transport-error retryScheduled")
            return
        }

        #expect(errorRetry.attemptNumber == 1)
        #expect(errorRetry.httpResponse == nil)
        #expect(errorRetry.transportError is EventTransportError)
        #expect(errorRetry.delay == .zero)
    }

    @Test("Authentication replay is published after its response and before the next attempt")
    func authenticationReplayEmitsOneImmediateReplayEvent() async throws {
        let capture = NetworkEventCapture()
        let endpoint = try Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(#require(URL(string: "https://events.test/auth"))),
            body: .data(),
            response: .data,
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        let client = try NetworkClient(
            transport: ScriptedEventTransport([.response(status: 401), .response(status: 200)]),
            configuration: .init()
                .withEventObserver(capture.observer)
                .withAuthenticationProvider(EventAuthenticationProvider()),
        )

        _ = try await client.task(for: Request(endpoint: endpoint, body: Data([0x01]))).value
        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == [
            "requestStarted",
            "attemptStarted",
            "responseReceived",
            "authenticationReplayScheduled",
            "attemptStarted",
            "responseReceived",
            "requestCompleted",
        ])
        guard case let .authenticationReplayScheduled(replay) = events[3] else {
            Issue.record("Expected authenticationReplayScheduled")
            return
        }

        #expect(replay.attemptNumber == 1)
        #expect(replay.httpResponse.status.code == 401)
        #expect(replay.rawTaskMetrics == nil)
        guard case let .requestCompleted(completed) = events.last else {
            Issue.record("Expected terminal completion")
            return
        }

        #expect(completed.attempts.map(\.attemptNumber) == [1, 2])
    }

    @Test("Validation rejection emits a response but not a transport attempt failure")
    func validationRejectionDoesNotEmitAttemptFailure() async throws {
        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: ScriptedEventTransport([.response(status: 500)]),
            configuration: .init().withEventObserver(capture.observer),
        )

        do {
            _ = try await client.task(for: makeGetEventRequest()).value
            Issue.record("Expected status validation to reject the response")
        } catch is ResponseValidationError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "responseReceived", "requestFailed"])
    }

    @Test("A decoding error follows response receipt and does not become an attempt failure")
    func decodingFailureEmitsRequestFailureOnly() async throws {
        let capture = NetworkEventCapture()
        let url = try #require(URL(string: "https://events.test/decode"))
        let endpoint = Endpoint<Never, Never, Int>.data(
            method: .get,
            route: .absolute(url),
            response: .json(),
        )
        let client = try NetworkClient(
            transport: ScriptedEventTransport([.response(status: 200, body: Data("not-json".utf8))]),
            configuration: .init().withEventObserver(capture.observer),
        )

        do {
            _ = try await client.task(for: Request(endpoint: endpoint)).value
            Issue.record("Expected decoding to reject invalid JSON")
        } catch is DecodingError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "responseReceived", "requestFailed"])
    }

    @Test("A blocked observer does not delay the request or another observer")
    func slowObserverDoesNotDelayNetworkingOrAnotherObserver() async throws {
        let gate = BlockingEventCallback()
        let fastCapture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: ImmediateEventTransport(),
            configuration: .init()
                .withEventObserver(NetworkEventObserver { _ in gate.pauseOnFirstCall() })
                .withEventObserver(fastCapture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())
        await gate.waitUntilBlocked()
        defer { gate.release() }

        let response = try await task.value
        let fastEvents = await fastCapture.eventsThroughTerminal()
        #expect(response.value == Data([0x2a]))
        #expect(fastEvents.map(\.kind) == ["requestStarted", "attemptStarted", "responseReceived", "requestCompleted"])
    }

    @Test("Observer queue overflow drops the oldest unprocessed event")
    func observerQueueDropsOldestPendingEvent() async {
        let gate = BlockingEventCallback()
        let capture = NetworkEventCapture()
        let delivery = NetworkEventDelivery(
            observers: [NetworkEventObserver { event in
                gate.pauseOnFirstCall()
                capture.continuation.yield(event)
            }],
            queueCapacity: 2,
            now: { Date(timeIntervalSince1970: 1) },
        )
        let identifiers = (0 ..< 4).map { _ in UUIDRequestIDGenerator().generateRequestID() }
        var iterator = capture.stream.makeAsyncIterator()

        for requestID in identifiers.prefix(1) {
            delivery.submit(.requestStarted(RequestStartedEvent(
                requestID: requestID,
                timestamp: Date(timeIntervalSince1970: 1),
                requestContext: RequestContext(),
            )))
        }
        await gate.waitUntilBlocked()
        for requestID in identifiers.dropFirst() {
            delivery.submit(.requestStarted(RequestStartedEvent(
                requestID: requestID,
                timestamp: Date(timeIntervalSince1970: 1),
                requestContext: RequestContext(),
            )))
        }
        gate.release()

        let events = await [iterator.next(), iterator.next(), iterator.next()].compactMap(\.self)
        #expect(events.map(\.requestID) == [identifiers[0], identifiers[2], identifiers[3]])
    }

    @Test("A follow decision remains follow when the redirect limit is exhausted")
    func redirectDecisionIsEvaluatedOnceAndPreservedAtLimit() async throws {
        let capture = NetworkEventCapture()
        let callCount = Mutex(0)
        let policy = RedirectPolicy.custom(maximumRedirects: 0) { _ in
            callCount.withLock { $0 += 1 }
            return .follow
        }
        let timestamp = Date(timeIntervalSince1970: 20)
        let delivery = NetworkEventDelivery(observers: [capture.observer], now: { timestamp })
        let requestID = UUIDRequestIDGenerator().generateRequestID()
        let initialURL = try #require(URL(string: "https://events.test/redirect"))
        let proposedURL = try #require(URL(string: "https://events.test/final"))
        let httpRequest = HTTPRequest(method: .get, url: initialURL)
        let eventExecution = NetworkEventExecution(
            requestID: requestID,
            requestContext: RequestContext(),
            delivery: delivery,
        )
        let transportRequest = TransportRequest(
            httpRequest: httpRequest,
            body: .none,
            redirectPolicy: policy,
            requestID: requestID,
            eventExecution: eventExecution,
        )
        let initialRequest = try #require(URLRequest(httpRequest: httpRequest))
        let delegate = URLSessionTaskMetricsDelegate(
            transportRequest: transportRequest,
            initialRequest: initialRequest,
        )
        let task = URLSession.shared.dataTask(with: initialRequest)
        let foundationResponse = try #require(HTTPURLResponse(
            url: initialURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": proposedURL.absoluteString],
        ))
        let proposedRequest = URLRequest(url: proposedURL)
        var followedRequest: URLRequest?

        delegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: foundationResponse,
            newRequest: proposedRequest,
            completionHandler: { followedRequest = $0 },
        )

        var iterator = capture.stream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(callCount.withLock { $0 } == 1)
        #expect(followedRequest == nil)
        #expect(delegate.redirectLimitExceeded() != nil)
        guard case let .redirectDecision(decision) = event else {
            Issue.record("Expected redirectDecision")
            return
        }

        #expect(decision.decision == .follow)
        #expect(decision.timestamp == timestamp)
        #expect(decision.attemptNumber == 1)
        #expect(decision.redirectOrdinal == 1)
        #expect(decision.proposedRequest.url == proposedURL)

        let rejectCapture = NetworkEventCapture()
        let rejectCalls = Mutex(0)
        let rejectPolicy = RedirectPolicy.custom(maximumRedirects: 0) { _ in
            rejectCalls.withLock { $0 += 1 }
            return .reject
        }
        let rejectDelivery = NetworkEventDelivery(observers: [rejectCapture.observer], now: { timestamp })
        let rejectExecution = NetworkEventExecution(
            requestID: requestID,
            requestContext: RequestContext(),
            delivery: rejectDelivery,
        )
        let rejectTransportRequest = TransportRequest(
            httpRequest: httpRequest,
            body: .none,
            redirectPolicy: rejectPolicy,
            requestID: requestID,
            eventExecution: rejectExecution,
        )
        let rejectDelegate = URLSessionTaskMetricsDelegate(
            transportRequest: rejectTransportRequest,
            initialRequest: initialRequest,
        )
        var rejectedRequest: URLRequest?
        rejectDelegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: foundationResponse,
            newRequest: proposedRequest,
            completionHandler: { rejectedRequest = $0 },
        )
        var rejectIterator = rejectCapture.stream.makeAsyncIterator()
        let rejectEvent = await rejectIterator.next()
        #expect(rejectCalls.withLock { $0 } == 1)
        #expect(rejectedRequest == nil)
        #expect(rejectDelegate.redirectLimitExceeded() == nil)
        guard case let .redirectDecision(rejected) = rejectEvent else {
            Issue.record("Expected rejected redirectDecision")
            return
        }

        #expect(rejected.decision == .reject)
    }

    @Test("Redirect limit failure follows the published follow decision")
    func redirectLimitFailurePublishesCompleteLifecycle() async throws {
        let capture = NetworkEventCapture()
        let policy = RedirectPolicy.custom(maximumRedirects: 0) { _ in .follow }
        let client = try NetworkClient(
            transport: RedirectLimitEventTransport(),
            configuration: .init().withEventObserver(capture.observer),
        )
        let request = try makeGetEventRequest().redirectPolicy(policy)
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected the redirect limit to fail the request")
        } catch is RedirectError {}

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == [
            "requestStarted",
            "attemptStarted",
            "redirectDecision",
            "attemptFailed",
            "requestFailed",
        ])
        #expect(events.filter(\.isTerminal).count == 1)

        guard case let .redirectDecision(decision) = events[2] else {
            Issue.record("Expected redirectDecision before redirect-limit failure")
            return
        }

        #expect(decision.decision == .follow)
        #expect(decision.proposedRequest.url == URL(string: "https://events.test/final"))

        guard case let .attemptFailed(attemptFailure) = events[3] else {
            Issue.record("Expected attemptFailed after the redirect decision")
            return
        }

        #expect(attemptFailure.error is RedirectError)
        #expect(attemptFailure.httpResponse?.status.code == 302)

        guard case let .requestFailed(requestFailure) = events[4] else {
            Issue.record("Expected requestFailed after attemptFailed")
            return
        }

        #expect(requestFailure.error is RedirectError)
    }

    @Test("Download finalization failure follows response receipt without failing the attempt")
    func downloadFinalizationFailureIsLogicalFailureOnly() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("network-event-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("existing.data")
        let originalContents = Data([0x71])
        try originalContents.write(to: destination)

        let capture = NetworkEventCapture()
        let client = try NetworkClient(
            transport: EventDownloadTransport(),
            configuration: .init().withEventObserver(capture.observer),
        )
        let request = try makeDownloadEventRequest(destination: destination)
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected download finalization to fail for an existing destination")
        } catch let error as DownloadFileError {
            if case .finalizationFailed = error {} else {
                Issue.record("Expected a finalizationFailed error, got \(error)")
            }
        } catch {
            Issue.record("Unexpected download failure: \(error)")
        }

        let events = await capture.eventsThroughTerminal()
        #expect(events.map(\.kind) == ["requestStarted", "attemptStarted", "responseReceived", "requestFailed"])
        #expect(events.filter(\.isTerminal).count == 1)
        #expect(!events.contains(where: { $0.kind == "attemptFailed" }))
        #expect(try Data(contentsOf: destination) == originalContents)

        guard case let .responseReceived(response) = events[2] else {
            Issue.record("Expected responseReceived before download finalization")
            return
        }

        #expect(response.httpResponse.status.code == 200)

        guard case let .requestFailed(requestFailure) = events[3] else {
            Issue.record("Expected finalization failure to terminate the logical request")
            return
        }
        guard let error = requestFailure.error as? DownloadFileError else {
            Issue.record("Expected requestFailed to retain DownloadFileError")
            return
        }

        if case .finalizationFailed = error {} else {
            Issue.record("Expected requestFailed to carry finalizationFailed")
        }
    }

    @Test("Completion racing shared cancellation publishes the winning terminal state once")
    func completionAndSharedCancellationRacePublishesWinningTerminalOnce() async throws {
        let capture = NetworkEventCapture()
        var iterator = capture.stream.makeAsyncIterator()
        let transport = BlockingEventTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try client.task(for: makeGetEventRequest())
        await transport.waitUntilStarted()

        let barrier = TwoPartyEventBarrier()
        let completer = Task {
            await barrier.wait()
            await transport.release()
        }
        let canceller = Task {
            await barrier.wait()
            task.cancel()
        }

        await completer.value
        await canceller.value

        let completed: Bool
        do {
            _ = try await task.value
            completed = true
        } catch is CancellationError {
            completed = false
        } catch {
            Issue.record("Unexpected shared execution failure: \(error)")
            return
        }

        let fenceTask = try client.task(for: makeGetEventRequest())
        _ = try await fenceTask.value
        var eventsBeforeFenceTerminal: [NetworkEvent] = []
        while let event = await iterator.next() {
            eventsBeforeFenceTerminal.append(event)
            if event.requestID == fenceTask.requestID, event.isTerminal {
                break
            }
        }

        let racedRequestEvents = eventsBeforeFenceTerminal.filter { $0.requestID == task.requestID }
        let terminalEvents = racedRequestEvents.filter(\.isTerminal)
        #expect(terminalEvents.count == 1)
        #expect(terminalEvents.first?.kind == (completed ? "requestCompleted" : "requestCancelled"))
    }

    @Test("Cancelling a value waiter does not cancel the shared request or release its observer")
    func waiterCancellationAndClientReleaseKeepSharedObservationAlive() async throws {
        let capture = NetworkEventCapture()
        let transport = BlockingEventTransport()
        var client: NetworkClient? = try NetworkClient(
            transport: transport,
            configuration: .init().withEventObserver(capture.observer),
        )
        let task = try #require(client?.task(for: makeGetEventRequest()))
        client = nil
        await transport.waitUntilStarted()

        let waiter = Task { try await task.value }
        waiter.cancel()

        do {
            _ = try await waiter.value
            Issue.record("Expected only the value waiter to be cancelled")
        } catch is CancellationError {}

        await transport.release()
        _ = try await task.value
        let events = await capture.eventsThroughTerminal()
        #expect(events.last?.kind == "requestCompleted")
        #expect(events.filter(\.isTerminal).count == 1)
    }
}

private func makeEventRequest() throws -> Request<Data> {
    let url = try #require(URL(string: "https://events.test/lifecycle"))
    let endpoint = Endpoint<Never, Data, Data>.data(
        method: .post,
        route: .absolute(url),
        body: .data(),
        response: .data,
    )
    return Request(endpoint: endpoint, body: Data([0x01]))
        .context(EventTraceKey.self, value: "event-context")
}

private func makeGetEventRequest() throws -> Request<Data> {
    let url = try #require(URL(string: "https://events.test/get"))
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint).context(EventTraceKey.self, value: "event-context")
}

private func makeDownloadEventRequest(destination: URL) throws -> Request<DownloadedFile> {
    let url = try #require(URL(string: "https://events.test/download"))
    let endpoint = Endpoint<Never, Never, DownloadedFile>.download(
        method: .get,
        route: .absolute(url),
    )
    return Request(endpoint: endpoint).downloadDestination(.file(destination))
}

private actor TaskStartDecisionCapture {
    private var decisions: [Bool] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func record(_ decision: Bool) {
        guard waiters.isEmpty == false else {
            decisions.append(decision)
            return
        }

        waiters.removeFirst().resume(returning: decision)
    }

    func next() async -> Bool {
        if decisions.isEmpty == false {
            return decisions.removeFirst()
        }

        return await withCheckedContinuation { waiters.append($0) }
    }
}

private class StartCommitURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "events.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [:],
              )
        else {
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x2a]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct NetworkEventCapture: Sendable {
    let stream: AsyncStream<NetworkEvent>
    fileprivate let continuation: AsyncStream<NetworkEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream<NetworkEvent>.makeStream()
    }

    var observer: NetworkEventObserver {
        NetworkEventObserver { event in
            continuation.yield(event)
        }
    }

    func eventsThroughTerminal() async -> [NetworkEvent] {
        var iterator = stream.makeAsyncIterator()
        var events: [NetworkEvent] = []
        while let event = await iterator.next() {
            events.append(event)
            if event.isTerminal {
                return events
            }
        }
        return events
    }
}

extension NetworkEvent {
    fileprivate var kind: String {
        switch self {
        case .requestStarted:
            "requestStarted"
        case .attemptStarted:
            "attemptStarted"
        case .responseReceived:
            "responseReceived"
        case .attemptFailed:
            "attemptFailed"
        case .authenticationReplayScheduled:
            "authenticationReplayScheduled"
        case .retryScheduled:
            "retryScheduled"
        case .redirectDecision:
            "redirectDecision"
        case .requestCompleted:
            "requestCompleted"
        case .requestFailed:
            "requestFailed"
        case .requestCancelled:
            "requestCancelled"
        }
    }

    fileprivate var isTerminal: Bool {
        switch self {
        case .requestCompleted,
             .requestFailed,
             .requestCancelled:
            true
        case .requestStarted,
             .attemptStarted,
             .responseReceived,
             .attemptFailed,
             .authenticationReplayScheduled,
             .retryScheduled,
             .redirectDecision:
            false
        }
    }

    fileprivate var requestID: RequestID {
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

    fileprivate var attemptNumber: UInt? {
        switch self {
        case let .attemptStarted(event):
            event.attemptNumber
        case let .responseReceived(event):
            event.attemptNumber
        case let .attemptFailed(event):
            event.attemptNumber
        case let .authenticationReplayScheduled(event):
            event.attemptNumber
        case let .retryScheduled(event):
            event.attemptNumber
        case let .redirectDecision(event):
            event.attemptNumber
        case .requestStarted,
             .requestCompleted,
             .requestFailed,
             .requestCancelled:
            nil
        }
    }

    fileprivate var timestamp: Date {
        switch self {
        case let .requestStarted(event):
            event.timestamp
        case let .attemptStarted(event):
            event.timestamp
        case let .responseReceived(event):
            event.timestamp
        case let .attemptFailed(event):
            event.timestamp
        case let .authenticationReplayScheduled(event):
            event.timestamp
        case let .retryScheduled(event):
            event.timestamp
        case let .redirectDecision(event):
            event.timestamp
        case let .requestCompleted(event):
            event.timestamp
        case let .requestFailed(event):
            event.timestamp
        case let .requestCancelled(event):
            event.timestamp
        }
    }

    fileprivate var trace: String? {
        switch self {
        case let .requestStarted(event):
            event.requestContext[EventTraceKey.self]
        case let .attemptStarted(event):
            event.requestContext[EventTraceKey.self]
        case let .responseReceived(event):
            event.requestContext[EventTraceKey.self]
        case let .attemptFailed(event):
            event.requestContext[EventTraceKey.self]
        case let .authenticationReplayScheduled(event):
            event.requestContext[EventTraceKey.self]
        case let .retryScheduled(event):
            event.requestContext[EventTraceKey.self]
        case let .redirectDecision(event):
            event.requestContext[EventTraceKey.self]
        case let .requestCompleted(event):
            event.requestContext[EventTraceKey.self]
        case let .requestFailed(event):
            event.requestContext[EventTraceKey.self]
        case let .requestCancelled(event):
            event.requestContext[EventTraceKey.self]
        }
    }
}

private struct ImmediateEventTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        (Data([0x2a]), HTTPResponse(status: .init(code: 200)))
    }
}

private actor BlockingEventTransport: NetworkTransport {
    private var continuation: CheckedContinuation<NetworkTransportResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw EventTransportError.unexpectedLegacyTransportCall
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        if released {
            return successfulResult
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let readyWaiters = startWaiters
            startWaiters.removeAll()
            for waiter in readyWaiters {
                waiter.resume()
            }
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil, released == false else {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        continuation?.resume(returning: successfulResult)
        continuation = nil
    }

    private var successfulResult: NetworkTransportResult {
        .success(
            data: Data([0x2a]),
            response: HTTPResponse(status: .init(code: 200)),
            rawTaskMetrics: nil,
        )
    }
}

private struct RedirectLimitEventTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw EventTransportError.unexpectedLegacyTransportCall
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        guard let initialRequest = URLRequest(httpRequest: request.httpRequest),
              let initialURL = initialRequest.url,
              let proposedURL = URL(string: "https://events.test/final"),
              let foundationResponse = HTTPURLResponse(
                  url: initialURL,
                  statusCode: 302,
                  httpVersion: nil,
                  headerFields: ["Location": proposedURL.absoluteString],
              ),
              let response = foundationResponse.httpResponse
        else {
            return .failure(error: EventTransportError.transportFailure, rawTaskMetrics: nil, didStartTask: true)
        }

        let delegate = URLSessionTaskMetricsDelegate(
            transportRequest: request,
            initialRequest: initialRequest,
            progressReporter: progress,
        )
        let task = URLSession.shared.dataTask(with: initialRequest)
        delegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: foundationResponse,
            newRequest: URLRequest(url: proposedURL),
            completionHandler: { _ in },
        )

        guard delegate.redirectLimitExceeded() != nil else {
            return .failure(error: EventTransportError.transportFailure, rawTaskMetrics: nil, didStartTask: true)
        }

        return .redirectLimitExceeded(
            maximumRedirects: request.redirectPolicy.maximumRedirects,
            lastResponse: response,
            rawTaskMetrics: nil,
        )
    }
}

private struct EventDownloadTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw EventTransportError.unexpectedLegacyTransportCall
    }

    func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        let foundationURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("network-event-download-\(UUID().uuidString)")
        do {
            try Data([0x7a, 0x7b]).write(to: foundationURL)
            let file = try DownloadedFileStorage.adopt(foundationURL)
            return .success(
                file: file,
                response: HTTPResponse(status: .init(code: 200)),
                rawTaskMetrics: nil,
            )
        } catch {
            return .failure(error: error, rawTaskMetrics: nil, didStartTask: true)
        }
    }
}

private actor ScriptedEventTransport: NetworkTransport {
    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        guard steps.isEmpty == false else {
            throw EventTransportError.unexpectedLegacyTransportCall
        }

        return try await result(for: steps.removeFirst())
    }

    private func result(for step: Step) async throws -> (Data, HTTPResponse) {
        switch step {
        case let .response(status, body):
            (body, HTTPResponse(status: .init(code: status)))
        case let .failure(error):
            throw error
        }
    }

    enum Step: Sendable {
        case response(status: Int, body: Data = Data([0x2a]))
        case failure(EventTransportError)
    }
}

private actor TwoPartyEventBarrier {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == 2 else {
                return
            }

            let readyWaiters = waiters
            waiters.removeAll()
            for waiter in readyWaiters {
                waiter.resume()
            }
        }
    }
}

private struct UnstartedEventTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw EventTransportError.transportFailure
    }

    func executeWithMetrics(
        _: TransportRequest,
        progress _: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        .failure(error: EventTransportError.transportFailure, rawTaskMetrics: nil, didStartTask: false)
    }
}

private struct StartedCancellationEventTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw CancellationError()
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        return .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: true)
    }
}

private struct EventAuthenticationProvider: AuthenticationProvider {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        context.request
    }

    func recover(_: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        .replay
    }
}

private final class BlockingEventCallback: Sendable {
    private let didPause = Mutex(false)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    func pauseOnFirstCall() {
        let shouldPause = didPause.withLock { didPause in
            guard didPause == false else {
                return false
            }

            didPause = true
            return true
        }
        guard shouldPause else {
            return
        }

        startedContinuation.yield(())
        releaseSemaphore.wait()
    }

    func waitUntilBlocked() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private enum EventTransportError: Error, Sendable {
    case unexpectedLegacyTransportCall
    case transportFailure
}

private enum EventTraceKey: RequestContextKey {
    typealias Value = String
}
