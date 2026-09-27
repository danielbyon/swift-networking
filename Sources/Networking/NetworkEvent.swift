//
//  NetworkEvent.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Dispatch
import Foundation
import HTTPTypes
import Synchronization

/// A lifecycle event published by a logical network execution.
///
/// Events add no request or response body fields. Original errors can retain associated metadata,
/// such as response content preserved by validation errors.
public enum NetworkEvent: Sendable {
    /// A logical execution has been assigned its request identity.
    case requestStarted(RequestStartedEvent)

    /// A transport task has begun for one attempt.
    case attemptStarted(AttemptStartedEvent)

    /// A transport attempt received an HTTP response.
    case responseReceived(ResponseReceivedEvent)

    /// A started transport attempt failed.
    case attemptFailed(AttemptFailedEvent)

    /// Authentication recovery selected an immediate replay.
    case authenticationReplayScheduled(AuthenticationReplayScheduledEvent)

    /// An ordinary retry was scheduled after its delay was resolved.
    case retryScheduled(RetryScheduledEvent)

    /// A proposed HTTP redirect was evaluated by the configured policy.
    case redirectDecision(RedirectDecisionEvent)

    /// The logical execution produced its response.
    case requestCompleted(RequestCompletedEvent)

    /// The logical execution failed.
    case requestFailed(RequestFailedEvent)

    /// Shared cancellation won the logical execution's terminal-state race.
    case requestCancelled(RequestCancelledEvent)
}

/// Identifies the start of one logical request before preflight begins.
public struct RequestStartedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    package init(requestID: RequestID, timestamp: Date, requestContext: RequestContext) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
    }
}

/// Describes a transport task that has begun for one attempt.
public struct AttemptStartedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of this task within the logical execution.
    public let attemptNumber: UInt

    /// The final adapted HTTP request sent by this attempt.
    public let request: HTTPRequest

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.request = request
    }
}

/// Describes an HTTP response delivered by a completed transport attempt.
public struct ResponseReceivedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of the task that received the response.
    public let attemptNumber: UInt

    /// The final adapted HTTP request sent by the attempt.
    public let request: HTTPRequest

    /// The HTTP response returned by the transport.
    public let httpResponse: HTTPResponse

    /// Stable library-owned diagnostics normalized from completed task metrics.
    public let normalizedMetrics: NormalizedAttemptMetrics

    /// The Foundation task metrics returned with the completed attempt, when available.
    public let rawTaskMetrics: URLSessionTaskMetrics?

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
        httpResponse: HTTPResponse,
        normalizedMetrics: NormalizedAttemptMetrics,
        rawTaskMetrics: URLSessionTaskMetrics?,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.request = request
        self.httpResponse = httpResponse
        self.normalizedMetrics = normalizedMetrics
        self.rawTaskMetrics = rawTaskMetrics
    }
}

/// Describes a failure from a started transport attempt.
public struct AttemptFailedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of the failed task within the logical execution.
    public let attemptNumber: UInt

    /// The final adapted HTTP request sent by the failed attempt.
    public let request: HTTPRequest

    /// The redirect response that exhausted the policy limit, when applicable.
    public let httpResponse: HTTPResponse?

    /// The heterogeneous error produced by the transport or redirect limit.
    public let error: any Error

    /// Stable library-owned diagnostics normalized from completed task metrics.
    public let normalizedMetrics: NormalizedAttemptMetrics

    /// The Foundation task metrics returned with the completed attempt, when available.
    public let rawTaskMetrics: URLSessionTaskMetrics?

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
        httpResponse: HTTPResponse? = nil,
        error: any Error,
        normalizedMetrics: NormalizedAttemptMetrics,
        rawTaskMetrics: URLSessionTaskMetrics?,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.request = request
        self.httpResponse = httpResponse
        self.error = error
        self.normalizedMetrics = normalizedMetrics
        self.rawTaskMetrics = rawTaskMetrics
    }
}

/// Describes an authentication provider's choice to replay an attempt immediately.
public struct AuthenticationReplayScheduledEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of the response that selected replay.
    public let attemptNumber: UInt

    /// The final adapted HTTP request that received the authentication response.
    public let request: HTTPRequest

    /// The response that caused authentication recovery to select replay.
    public let httpResponse: HTTPResponse

    /// Stable library-owned diagnostics normalized from completed task metrics.
    public let normalizedMetrics: NormalizedAttemptMetrics

    /// The Foundation task metrics returned with the completed attempt, when available.
    public let rawTaskMetrics: URLSessionTaskMetrics?

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
        httpResponse: HTTPResponse,
        normalizedMetrics: NormalizedAttemptMetrics,
        rawTaskMetrics: URLSessionTaskMetrics?,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.request = request
        self.httpResponse = httpResponse
        self.normalizedMetrics = normalizedMetrics
        self.rawTaskMetrics = rawTaskMetrics
    }
}

/// Describes an ordinary retry after its final delay has been calculated.
public struct RetryScheduledEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of the attempt that scheduled the retry.
    public let attemptNumber: UInt

    /// The final adapted HTTP request sent by the attempt.
    public let request: HTTPRequest

    /// The response that selected retry, or nil when a transport error did.
    public let httpResponse: HTTPResponse?

    /// The transport error that selected retry, or nil for response-driven retries.
    public let transportError: (any Error)?

    /// The final delay after backoff, jitter, and Retry-After resolution.
    public let delay: Duration

    /// Stable library-owned diagnostics normalized from completed task metrics.
    public let normalizedMetrics: NormalizedAttemptMetrics

    /// The Foundation task metrics returned with the completed attempt, when available.
    public let rawTaskMetrics: URLSessionTaskMetrics?

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
        httpResponse: HTTPResponse?,
        transportError: (any Error)?,
        delay: Duration,
        normalizedMetrics: NormalizedAttemptMetrics,
        rawTaskMetrics: URLSessionTaskMetrics?,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.request = request
        self.httpResponse = httpResponse
        self.transportError = transportError
        self.delay = delay
        self.normalizedMetrics = normalizedMetrics
        self.rawTaskMetrics = rawTaskMetrics
    }
}

/// Describes the policy decision for one proposed HTTP redirect.
public struct RedirectDecisionEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The one-based position of the task evaluating the redirect.
    public let attemptNumber: UInt

    /// The one-based proposal position within this transport attempt.
    public let redirectOrdinal: UInt

    /// The HTTP response that proposed the redirect.
    public let httpResponse: HTTPResponse

    /// The bodyless HTTP request Foundation proposed for the redirect.
    public let proposedRequest: HTTPRequest

    /// The single decision returned by the configured redirect policy.
    public let decision: RedirectPolicy.Decision

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        redirectOrdinal: UInt,
        httpResponse: HTTPResponse,
        proposedRequest: HTTPRequest,
        decision: RedirectPolicy.Decision,
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
        self.redirectOrdinal = redirectOrdinal
        self.httpResponse = httpResponse
        self.proposedRequest = proposedRequest
        self.decision = decision
    }
}

/// Describes successful completion of a logical request.
public struct RequestCompletedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The HTTP response returned to the caller.
    public let httpResponse: HTTPResponse

    /// Metrics for every transport attempt in the completed execution.
    public let attempts: [AttemptMetrics]

    package init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        httpResponse: HTTPResponse,
        attempts: [AttemptMetrics],
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.httpResponse = httpResponse
        self.attempts = attempts
    }
}

/// Describes failure of a logical request.
public struct RequestFailedEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// The original heterogeneous error returned by the execution pipeline.
    ///
    /// Error values may expose associated metadata, including retained validation response content.
    public let error: any Error

    package init(requestID: RequestID, timestamp: Date, requestContext: RequestContext, error: any Error) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
        self.error = error
    }
}

/// Describes shared cancellation of a logical request.
public struct RequestCancelledEvent: Sendable {
    /// The identity shared by every attempt in the logical execution.
    public let requestID: RequestID

    /// The wall-clock time at which the event was submitted.
    public let timestamp: Date

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    package init(requestID: RequestID, timestamp: Date, requestContext: RequestContext) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.requestContext = requestContext
    }
}

/// Delivers lifecycle events to one consumer.
///
/// The callback is synchronous and nonthrowing, but Networking invokes it asynchronously on a
/// dedicated delivery queue. Request execution only submits events and never waits for callbacks.
public struct NetworkEventObserver: Sendable {
    package let callback: @Sendable (NetworkEvent) -> Void

    /// Creates an observer from a synchronous event callback.
    ///
    /// The callback is delivered asynchronously from request execution.
    ///
    /// - Parameter callback: The closure that handles each delivered event.
    public init(_ callback: @escaping @Sendable (NetworkEvent) -> Void) {
        self.callback = callback
    }
}

/// Retains one bounded serial delivery queue per configured observer.
package final class NetworkEventDelivery: Sendable {
    private static let defaultQueueCapacity = 64

    private let observers: [NetworkEventObserverQueue]
    private let now: @Sendable () -> Date

    package convenience init(
        observers: [NetworkEventObserver],
        now: @escaping @Sendable () -> Date,
    ) {
        self.init(observers: observers, queueCapacity: Self.defaultQueueCapacity, now: now)
    }

    package init(
        observers: [NetworkEventObserver],
        queueCapacity: Int,
        now: @escaping @Sendable () -> Date,
    ) {
        precondition(queueCapacity > 0)
        self.observers = observers.map { NetworkEventObserverQueue(observer: $0, capacity: queueCapacity) }
        self.now = now
    }

    package func timestamp() -> Date {
        observers.isEmpty ? .distantPast : now()
    }

    package func submit(_ event: NetworkEvent) {
        for observer in observers {
            observer.enqueue(event)
        }
    }
}

/// Serializes bounded event delivery for a single observer.
private final class NetworkEventObserverQueue: Sendable {
    private struct State: Sendable {
        var events: [NetworkEvent] = []
        var isDraining = false
    }

    private let observer: NetworkEventObserver
    private let capacity: Int
    private let queue = DispatchQueue(label: "swift-networking.events.\(UUID().uuidString)")
    private let state = Mutex(State())

    init(observer: NetworkEventObserver, capacity: Int) {
        self.observer = observer
        self.capacity = capacity
    }

    func enqueue(_ event: NetworkEvent) {
        let shouldScheduleDrain = state.withLock { state in
            if state.events.count == capacity {
                state.events.removeFirst()
            }
            state.events.append(event)
            guard state.isDraining == false else {
                return false
            }

            state.isDraining = true
            return true
        }

        if shouldScheduleDrain {
            queue.async { [self] in
                drain()
            }
        }
    }

    private func drain() {
        while true {
            let event = state.withLock { state -> NetworkEvent? in
                guard state.events.isEmpty == false else {
                    state.isDraining = false
                    return nil
                }

                return state.events.removeFirst()
            }

            guard let event else {
                return
            }

            observer.callback(event)
        }
    }
}

/// Coordinates one logical execution's event submission and actual attempt-start callbacks.
package final class NetworkEventExecution: Sendable {
    private struct State: Sendable {
        var attemptRequests: [UInt: HTTPRequest] = [:]
        var isTerminal = false
    }

    package let requestID: RequestID
    package let requestContext: RequestContext
    package let delivery: NetworkEventDelivery

    private let state = Mutex(State())

    package init(requestID: RequestID, requestContext: RequestContext, delivery: NetworkEventDelivery) {
        self.requestID = requestID
        self.requestContext = requestContext
        self.delivery = delivery
    }

    package func submit(_ event: NetworkEvent) {
        state.withLock { state in
            guard state.isTerminal == false else {
                return
            }

            delivery.submit(event)
        }
    }

    package func submitTerminal(_ event: NetworkEvent) {
        state.withLock { state in
            guard state.isTerminal == false else {
                return
            }

            state.isTerminal = true
            state.attemptRequests.removeAll()
            delivery.submit(event)
        }
    }

    package func prepareAttempt(number: UInt, request: HTTPRequest) {
        state.withLock { state in
            guard state.isTerminal == false else {
                return
            }

            state.attemptRequests[number] = request
        }
    }

    package func attemptStarted(number: UInt) {
        let request = state.withLock { state -> HTTPRequest? in
            guard state.isTerminal == false else {
                return nil
            }

            return state.attemptRequests.removeValue(forKey: number)
        }
        guard let request else {
            return
        }

        submit(
            .attemptStarted(
                AttemptStartedEvent(
                    requestID: requestID,
                    timestamp: delivery.timestamp(),
                    requestContext: requestContext,
                    attemptNumber: number,
                    request: request,
                ),
            ),
        )
    }
}
