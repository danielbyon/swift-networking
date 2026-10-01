//
//  RedirectEvaluation.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Per-attempt redirect accounting shared by URLSession and TestSupport transports.
///
/// Redirect proposals remain part of the transport attempt that received the initial request, so
/// the accounting in this value never crosses attempts or logical executions.
package struct RedirectEvaluationState: Sendable {
    /// The number of proposals evaluated during the current transport attempt.
    package var redirectOrdinal: UInt = 0

    /// The number of proposals followed during the current transport attempt.
    package var followedRedirectCount: UInt = 0

    /// The recorded limit failure once a follow decision exceeds the policy budget.
    package var limitExceeded: RedirectLimitExceeded?

    package init() {}
}

/// The disposition of one redirect proposal after the configured policy evaluates it.
package enum RedirectEvaluationOutcome: Sendable {
    /// The policy allowed the proposal and the attempt still has follow budget.
    case follow

    /// The policy rejected the proposal, so the redirect response is the attempt's final response.
    case reject

    /// The policy allowed the proposal but the attempt exhausted its follow budget.
    case limitExceeded(RedirectLimitExceeded)
}

/// Evaluates one redirect proposal with identical decision, event, and limit semantics everywhere.
///
/// The URLSession delegate and the TestSupport mock transport both call this helper so deterministic
/// tests exercise the same policy decisions, per-attempt redirect limits, and redirect lifecycle
/// events as live transport execution.
///
/// Callers must verify that both the current and proposed requests are representable as
/// `HTTPRequest` values before evaluating a proposal, because every evaluated proposal reports a
/// `redirectDecision` event and an unrepresentable proposal cannot describe that event.
///
/// - Parameters:
///   - state: The per-attempt redirect accounting to update.
///   - policy: The immutable redirect policy selected for the logical request.
///   - currentRequest: The Foundation request the transport is currently executing.
///   - proposedRequest: The Foundation request the transport proposes to use next.
///   - httpResponse: The HTTP response that proposed the redirect.
///   - requestID: The identity shared by all attempts in the logical execution.
///   - requestContext: Typed metadata associated with the logical request.
///   - attemptNumber: The one-based attempt containing this proposal.
///   - proposedHTTPRequest: The proposed request in HTTP form, which the reported decision describes.
///   - eventExecution: The attempt's event submission context, or `nil` when events are unavailable.
/// - Returns: Whether the transport follows the proposal, keeps the redirect response, or stops at the limit.
package func evaluateRedirectProposal(
    state: inout RedirectEvaluationState,
    policy: RedirectPolicy,
    currentRequest: URLRequest,
    proposedRequest: URLRequest,
    httpResponse: HTTPResponse,
    requestID: RequestID,
    requestContext: RequestContext,
    attemptNumber: UInt,
    proposedHTTPRequest: HTTPRequest,
    eventExecution: NetworkEventExecution?,
) -> RedirectEvaluationOutcome {
    state.redirectOrdinal += 1
    let redirectOrdinal = state.redirectOrdinal

    let context = RedirectPolicy.Context(
        currentRequest: currentRequest,
        proposedRequest: proposedRequest,
        httpResponse: httpResponse,
        requestID: requestID,
        requestContext: requestContext,
        attemptNumber: attemptNumber,
        redirectOrdinal: redirectOrdinal,
    )
    let decision = policy.decision(for: context)

    if let eventExecution {
        eventExecution.submit(
            .redirectDecision(
                RedirectDecisionEvent(
                    requestID: requestID,
                    timestamp: eventExecution.delivery.timestamp(),
                    requestContext: requestContext,
                    attemptNumber: attemptNumber,
                    redirectOrdinal: redirectOrdinal,
                    httpResponse: httpResponse,
                    proposedRequest: proposedHTTPRequest,
                    decision: decision,
                ),
            ),
        )
    }

    guard decision == .follow else {
        return .reject
    }
    guard state.followedRedirectCount >= policy.maximumRedirects else {
        state.followedRedirectCount += 1
        return .follow
    }

    let limit = RedirectLimitExceeded(
        maximumRedirects: policy.maximumRedirects,
        lastResponse: httpResponse,
    )
    state.limitExceeded = limit
    return .limitExceeded(limit)
}
