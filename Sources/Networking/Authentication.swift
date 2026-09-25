//
//  Authentication.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

/// Declares whether an endpoint requires provider-driven request authentication and recovery.
public enum AuthenticationRequirement: Sendable, Equatable {
    /// Sends the request without invoking the client's authentication provider.
    case none

    /// Authenticates each attempt and permits a bounded number of provider-requested replays.
    ///
    /// - Parameter maximumReplays: The maximum number of immediate authentication replays.
    case required(maximumReplays: UInt = 1)
}

/// The result of an authentication provider's response-recovery decision.
public enum AuthenticationRecovery: Sendable {
    /// Immediately rebuild and send the authenticated request again.
    case replay

    /// Continue the response through ordinary retry selection and validation.
    case doNotReplay
}

/// Immutable request and response state supplied when an authenticated response is recovered.
public struct AuthenticationRecoveryContext: Sendable {
    /// The final HTTP request returned by authentication adaptation for the completed attempt.
    public let request: HTTPRequest

    /// The HTTP response returned by the transport.
    public let httpResponse: HTTPResponse

    /// The response body returned by the transport.
    public let receivedBody: ReceivedResponseBody

    /// Typed values associated with the logical request.
    public let requestContext: RequestContext

    /// The identity of the logical execution that received the response.
    public let requestID: RequestID

    /// The one-based number of the completed transport attempt.
    public let attemptNumber: UInt

    package init(
        request: HTTPRequest,
        httpResponse: HTTPResponse,
        receivedBody: ReceivedResponseBody,
        requestContext: RequestContext,
        requestID: RequestID,
        attemptNumber: UInt,
    ) {
        self.request = request
        self.httpResponse = httpResponse
        self.receivedBody = receivedBody
        self.requestContext = requestContext
        self.requestID = requestID
        self.attemptNumber = attemptNumber
    }
}

/// Describes a required endpoint authentication configuration that the client cannot satisfy.
public struct AuthenticationConfigurationError: Error, Sendable, Equatable {
    /// The identity of the logical execution that could not be configured.
    public let requestID: RequestID

    package init(requestID: RequestID) {
        self.requestID = requestID
    }
}

/// Supplies final request adaptation and response recovery while retaining credential ownership.
public protocol AuthenticationProvider: Sendable {
    /// Returns the request to send after all general request adapters have run.
    ///
    /// Errors propagate unchanged and prevent the transport attempt from starting.
    ///
    /// - Parameter context: The current request and immutable execution metadata.
    /// - Returns: The final request for the transport attempt.
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest

    /// Decides whether a completed authenticated response should immediately replay the request.
    ///
    /// Errors propagate unchanged and stop response processing before ordinary retry or validation.
    ///
    /// - Parameter context: The final request, response, body, and execution metadata.
    /// - Returns: Whether to replay within the endpoint's remaining authentication budget.
    func recover(_ context: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery
}
