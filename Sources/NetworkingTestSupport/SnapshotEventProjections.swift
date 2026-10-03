//
//  SnapshotEventProjections.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking

/// A rendering of an event that carries request identity and metadata only.
struct SnapshotLifecycleEvent: Sendable, Equatable {
    let requestID: String
    let timestamp: String
    let requestContext: [RequestContextDiagnosticEntry]

    init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        renderer: SnapshotProjectionRenderer,
    ) {
        self.requestID = renderer.requestID(requestID)
        self.timestamp = renderer.timestamp(timestamp)
        self.requestContext = requestContext.diagnosticRepresentation
    }

    init(_ payload: RequestCancelledEvent, renderer: SnapshotProjectionRenderer) {
        self.init(
            requestID: payload.requestID,
            timestamp: payload.timestamp,
            requestContext: payload.requestContext,
            renderer: renderer,
        )
    }
}

/// A rendering of an event that describes one transport attempt.
struct SnapshotAttemptEvent: Sendable, Equatable {
    let requestID: String
    let timestamp: String
    let requestContext: [RequestContextDiagnosticEntry]
    let attemptNumber: UInt
    let request: SnapshotHTTPRequest
    let httpResponse: SnapshotHTTPResponse?
    let error: String?
    let delay: String?
    let normalizedMetrics: SnapshotNormalizedMetrics?
    let rawTaskMetrics: String

    init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        attemptNumber: UInt,
        request: HTTPRequest,
        httpResponse: HTTPResponse? = nil,
        error: (any Error)? = nil,
        delay: Duration? = nil,
        normalizedMetrics: NormalizedAttemptMetrics?,
        rawTaskMetrics: URLSessionTaskMetrics?,
        renderer: SnapshotProjectionRenderer,
    ) {
        self.requestID = renderer.requestID(requestID)
        self.timestamp = renderer.timestamp(timestamp)
        self.requestContext = requestContext.diagnosticRepresentation
        self.attemptNumber = attemptNumber
        self.request = SnapshotHTTPRequest(request, renderer: renderer)
        self.httpResponse = httpResponse.map { SnapshotHTTPResponse($0, renderer: renderer) }
        self.error = error.map(renderer.errorIdentity)
        self.delay = delay.map(renderer.duration)
        self.normalizedMetrics = normalizedMetrics.map { SnapshotNormalizedMetrics($0, renderer: renderer) }
        self.rawTaskMetrics = renderer.rawTaskMetrics(rawTaskMetrics)
    }
}

/// A rendering of one evaluated redirect proposal.
struct SnapshotRedirectDecisionEvent: Sendable, Equatable {
    let requestID: String
    let timestamp: String
    let requestContext: [RequestContextDiagnosticEntry]
    let attemptNumber: UInt
    let redirectOrdinal: UInt
    let response: SnapshotHTTPResponse
    let proposedRequest: SnapshotHTTPRequest
    let decision: RedirectPolicy.Decision

    init(_ payload: RedirectDecisionEvent, renderer: SnapshotProjectionRenderer) {
        requestID = renderer.requestID(payload.requestID)
        timestamp = renderer.timestamp(payload.timestamp)
        requestContext = payload.requestContext.diagnosticRepresentation
        attemptNumber = payload.attemptNumber
        redirectOrdinal = payload.redirectOrdinal
        response = SnapshotHTTPResponse(payload.httpResponse, renderer: renderer)
        proposedRequest = SnapshotHTTPRequest(payload.proposedRequest, renderer: renderer)
        decision = payload.decision
    }
}

/// A rendering of a successful logical completion and its attempt history.
struct SnapshotCompletedEvent: Sendable, Equatable {
    let requestID: String
    let timestamp: String
    let requestContext: [RequestContextDiagnosticEntry]
    let httpResponse: SnapshotHTTPResponse
    let attempts: [SnapshotAttemptMetrics]

    init(_ payload: RequestCompletedEvent, renderer: SnapshotProjectionRenderer) {
        requestID = renderer.requestID(payload.requestID)
        timestamp = renderer.timestamp(payload.timestamp)
        requestContext = payload.requestContext.diagnosticRepresentation
        httpResponse = SnapshotHTTPResponse(payload.httpResponse, renderer: renderer)
        attempts = payload.attempts.map { SnapshotAttemptMetrics($0, renderer: renderer) }
    }
}

/// A rendering of a failed logical completion.
struct SnapshotTerminalEvent: Sendable, Equatable {
    let requestID: String
    let timestamp: String
    let requestContext: [RequestContextDiagnosticEntry]
    let error: String

    init(
        requestID: RequestID,
        timestamp: Date,
        requestContext: RequestContext,
        error: any Error,
        renderer: SnapshotProjectionRenderer,
    ) {
        self.requestID = renderer.requestID(requestID)
        self.timestamp = renderer.timestamp(timestamp)
        self.requestContext = requestContext.diagnosticRepresentation
        self.error = renderer.errorIdentity(error)
    }

    init(_ payload: RequestFailedEvent, renderer: SnapshotProjectionRenderer) {
        self.init(
            requestID: payload.requestID,
            timestamp: payload.timestamp,
            requestContext: payload.requestContext,
            error: payload.error,
            renderer: renderer,
        )
    }
}

/// A rendering of one lifecycle event with privacy-safe payload details.
enum SnapshotNetworkEvent: Sendable, Equatable {
    case requestStarted(SnapshotLifecycleEvent)
    case attemptStarted(SnapshotAttemptEvent)
    case responseReceived(SnapshotAttemptEvent)
    case attemptFailed(SnapshotAttemptEvent)
    case authenticationReplayScheduled(SnapshotAttemptEvent)
    case retryScheduled(SnapshotAttemptEvent)
    case redirectDecision(SnapshotRedirectDecisionEvent)
    case requestCompleted(SnapshotCompletedEvent)
    case requestFailed(SnapshotTerminalEvent)
    case requestCancelled(SnapshotLifecycleEvent)

    init(_ event: NetworkEvent, renderer: SnapshotProjectionRenderer) {
        switch event {
        case let .requestStarted(payload):
            self = .requestStarted(SnapshotLifecycleEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                renderer: renderer,
            ))
        case let .attemptStarted(payload):
            self = .attemptStarted(SnapshotAttemptEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                attemptNumber: payload.attemptNumber,
                request: payload.request,
                normalizedMetrics: nil,
                rawTaskMetrics: nil,
                renderer: renderer,
            ))
        case let .responseReceived(payload):
            self = .responseReceived(SnapshotAttemptEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                attemptNumber: payload.attemptNumber,
                request: payload.request,
                httpResponse: payload.httpResponse,
                normalizedMetrics: payload.normalizedMetrics,
                rawTaskMetrics: payload.rawTaskMetrics,
                renderer: renderer,
            ))
        case let .attemptFailed(payload):
            self = .attemptFailed(SnapshotAttemptEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                attemptNumber: payload.attemptNumber,
                request: payload.request,
                httpResponse: payload.httpResponse,
                error: payload.error,
                normalizedMetrics: payload.normalizedMetrics,
                rawTaskMetrics: payload.rawTaskMetrics,
                renderer: renderer,
            ))
        case let .authenticationReplayScheduled(payload):
            self = .authenticationReplayScheduled(SnapshotAttemptEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                attemptNumber: payload.attemptNumber,
                request: payload.request,
                httpResponse: payload.httpResponse,
                normalizedMetrics: payload.normalizedMetrics,
                rawTaskMetrics: payload.rawTaskMetrics,
                renderer: renderer,
            ))
        case let .retryScheduled(payload):
            self = .retryScheduled(SnapshotAttemptEvent(
                requestID: payload.requestID,
                timestamp: payload.timestamp,
                requestContext: payload.requestContext,
                attemptNumber: payload.attemptNumber,
                request: payload.request,
                httpResponse: payload.httpResponse,
                error: payload.transportError,
                delay: payload.delay,
                normalizedMetrics: payload.normalizedMetrics,
                rawTaskMetrics: payload.rawTaskMetrics,
                renderer: renderer,
            ))
        case let .redirectDecision(payload):
            self = .redirectDecision(SnapshotRedirectDecisionEvent(payload, renderer: renderer))
        case let .requestCompleted(payload):
            self = .requestCompleted(SnapshotCompletedEvent(payload, renderer: renderer))
        case let .requestFailed(payload):
            self = .requestFailed(SnapshotTerminalEvent(payload, renderer: renderer))
        case let .requestCancelled(payload):
            self = .requestCancelled(SnapshotLifecycleEvent(payload, renderer: renderer))
        }
    }
}

extension NetworkEvent {
    /// The logical request identity every event case carries.
    ///
    /// Snapshot strategies read this before projecting so the sanitized placeholders can keep the
    /// identity relationships of a sequence instead of collapsing every identity together.
    var projectionRequestID: RequestID {
        switch self {
        case let .requestStarted(payload):
            payload.requestID
        case let .attemptStarted(payload):
            payload.requestID
        case let .responseReceived(payload):
            payload.requestID
        case let .attemptFailed(payload):
            payload.requestID
        case let .authenticationReplayScheduled(payload):
            payload.requestID
        case let .retryScheduled(payload):
            payload.requestID
        case let .redirectDecision(payload):
            payload.requestID
        case let .requestCompleted(payload):
            payload.requestID
        case let .requestFailed(payload):
            payload.requestID
        case let .requestCancelled(payload):
            payload.requestID
        }
    }
}
