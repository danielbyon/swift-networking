//
//  RetryPolicy.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// An immutable policy for bounded, immediate retries of HTTP responses and transport failures.
///
/// Retries are disabled by default. A policy can be replaced at client, endpoint, or request
/// scope. Its mutable `Configuration` is used only while constructing this value.
public struct RetryPolicy: Sendable {
    /// The reason the built-in rules proposed retrying or stopping.
    public enum Reason: Sendable, Equatable {
        /// The HTTP method is not in the policy's retryable method set.
        case methodNotRetryable(HTTPRequest.Method)

        /// The response status is not in the policy's retryable status set.
        case statusCodeNotRetryable(Int)

        /// The response status is in the policy's retryable status set.
        case statusCodeRetryable(Int)

        /// The transport error is not a retryable URL error code.
        case urlErrorCodeNotRetryable(URLError.Code)

        /// The transport error is a retryable URL error code.
        case urlErrorCodeRetryable(URLError.Code)

        /// The transport error is not a `URLError` and has no built-in retry classification.
        case nonURLErrorTransportFailure
    }

    /// The custom decision returned by a policy's synchronous decision closure.
    public enum Decision: Sendable, Equatable {
        /// Use the built-in proposal carried by the context.
        case useBuiltInDecision

        /// Retry if retry budget remains and the current task is not cancelled.
        case retry

        /// Do not retry.
        case doNotRetry
    }

    /// Metadata available while deciding whether one completed transport attempt should retry.
    ///
    /// The response body and request body are omitted so retry policy code cannot retain payloads.
    public struct Context: Sendable {
        /// The result proposed by built-in retry classification.
        public let builtInDecision: Decision

        /// The explanation for the built-in proposal.
        public let builtInReason: Reason

        /// The HTTP method used for the attempt.
        public let method: HTTPRequest.Method

        /// The HTTP response metadata, when the transport returned a response.
        public let response: HTTPResponse?

        /// The exact error returned by the transport, when the transport failed.
        public let transportError: (any Error)?

        /// The typed request metadata associated with the logical execution.
        public let context: RequestContext

        /// The identity shared by every transport attempt in the logical execution.
        public let requestID: RequestID

        /// The one-based number of the transport attempt that just completed.
        public let attemptNumber: UInt

        /// The number of retries already scheduled for this logical execution.
        public let retryCount: UInt

        package init(
            builtInDecision: Decision,
            builtInReason: Reason,
            method: HTTPRequest.Method,
            response: HTTPResponse?,
            transportError: (any Error)?,
            context: RequestContext,
            requestID: RequestID,
            attemptNumber: UInt,
            retryCount: UInt,
        ) {
            self.builtInDecision = builtInDecision
            self.builtInReason = builtInReason
            self.method = method
            self.response = response
            self.transportError = transportError
            self.context = context
            self.requestID = requestID
            self.attemptNumber = attemptNumber
            self.retryCount = retryCount
        }
    }

    /// Construction-only mutable values for creating an immutable retry policy.
    public struct Configuration: Sendable {
        /// The maximum number of retries after the initial transport attempt.
        public var maximumRetries: UInt

        /// HTTP methods eligible for built-in status and transport retries.
        public var retryableMethods: Set<HTTPRequest.Method>

        /// HTTP status codes eligible for a built-in response retry.
        public var retryableStatusCodes: Set<Int>

        /// URL error codes eligible for built-in transport retry. Cancellation always remains excluded.
        public var retryableURLErrorCodes: Set<URLError.Code>

        /// An optional synchronous override evaluated while retry budget remains.
        public var customDecision: (@Sendable (Context) -> Decision)?

        /// Creates builder state using the library's built-in eligibility defaults.
        public init() {
            maximumRetries = 0
            retryableMethods = [.get, .head, .options, .trace, .put, .delete]
            retryableStatusCodes = [408, 429, 500, 502, 503, 504]
            retryableURLErrorCodes = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
            ]
            customDecision = nil
        }
    }

    /// The maximum number of retries after the initial transport attempt.
    public let maximumRetries: UInt

    /// HTTP methods eligible for built-in status and transport retries.
    public let retryableMethods: Set<HTTPRequest.Method>

    /// HTTP status codes eligible for a built-in response retry.
    public let retryableStatusCodes: Set<Int>

    /// URL error codes eligible for built-in transport retry. Cancellation always remains excluded.
    public let retryableURLErrorCodes: Set<URLError.Code>

    /// The optional synchronous override evaluated while retry budget remains.
    public let customDecision: (@Sendable (Context) -> Decision)?

    /// Creates the default policy, which disables retries.
    public init() {
        self.init(configuration: Configuration())
    }

    /// Creates an immutable policy from construction-only mutable configuration.
    public init(configuration: Configuration) {
        maximumRetries = configuration.maximumRetries
        retryableMethods = configuration.retryableMethods
        retryableStatusCodes = configuration.retryableStatusCodes
        retryableURLErrorCodes = configuration.retryableURLErrorCodes
        customDecision = configuration.customDecision
    }

    /// Creates an immutable policy by configuring fresh default builder state.
    ///
    /// This initializer is the common construction path used by endpoint and request builder
    /// modifiers. The builder is discarded after this initializer returns.
    public init(configure: @Sendable (inout Configuration) -> Void) {
        var configuration = Configuration()
        configure(&configuration)
        self.init(configuration: configuration)
    }

    package func builtInClassification(
        method: HTTPRequest.Method,
        response: HTTPResponse? = nil,
        transportError: (any Error)? = nil,
    ) -> (decision: Decision, reason: Reason) {
        guard retryableMethods.contains(method) else {
            return (.doNotRetry, .methodNotRetryable(method))
        }

        if let response {
            let statusCode = response.status.code
            guard retryableStatusCodes.contains(statusCode) else {
                return (.doNotRetry, .statusCodeNotRetryable(statusCode))
            }

            return (.retry, .statusCodeRetryable(statusCode))
        }

        guard let transportError else {
            return (.doNotRetry, .nonURLErrorTransportFailure)
        }
        guard let urlError = transportError as? URLError else {
            return (.doNotRetry, .nonURLErrorTransportFailure)
        }
        guard urlError.code != .cancelled, retryableURLErrorCodes.contains(urlError.code) else {
            return (.doNotRetry, .urlErrorCodeNotRetryable(urlError.code))
        }

        return (.retry, .urlErrorCodeRetryable(urlError.code))
    }
}
