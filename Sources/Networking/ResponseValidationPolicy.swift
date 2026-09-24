//
//  ResponseValidationPolicy.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// The received response body supplied to a response-validation policy.
public enum ReceivedResponseBody: Sendable {
    /// The response bytes returned by an in-memory data transport.
    case data(Data)

    /// A library-owned response file available only during the validation callback.
    ///
    /// The file is read-only and callback-scoped. Validation and authentication code must not
    /// move or delete it, or retain its URL as a durable file reference.
    case file(URL)
}

/// Immutable response and request state supplied to a response-validation policy.
public struct ResponseValidationContext: Sendable {
    /// The HTTP response metadata returned by the transport.
    public let httpResponse: HTTPResponse

    /// The response body representation returned by the transport.
    public let receivedBody: ReceivedResponseBody

    /// The identity of the logical execution that received the response.
    public let requestID: RequestID

    /// Typed values associated with the logical request.
    public let requestContext: RequestContext

    package init(
        httpResponse: HTTPResponse,
        receivedBody: ReceivedResponseBody,
        requestID: RequestID,
        requestContext: RequestContext,
    ) {
        self.httpResponse = httpResponse
        self.receivedBody = receivedBody
        self.requestID = requestID
        self.requestContext = requestContext
    }
}

/// The decision returned by a response-validation policy.
public enum ResponseValidationResult: Sendable, Equatable {
    /// Accept the response and continue to response decoding.
    case accept

    /// Reject the response before response decoding, optionally providing a diagnostic reason.
    case reject(reason: String? = nil)
}

/// A synchronous, nonthrowing policy for deciding whether a transport response is acceptable.
public struct ResponseValidationPolicy: Sendable {
    private let validateResponse: @Sendable (ResponseValidationContext) -> ResponseValidationResult

    private init(validate: @escaping @Sendable (ResponseValidationContext) -> ResponseValidationResult) {
        validateResponse = validate
    }

    /// Accepts HTTP status codes from 200 through 299 and rejects every other status code.
    public static let successfulStatusCodes = Self { context in
        let statusCode = context.httpResponse.status.code
        if statusCode >= 200, statusCode < 300 {
            return .accept
        }
        return .reject()
    }

    /// Creates a policy from a synchronous, nonthrowing response-validation closure.
    ///
    /// - Parameter validate: The closure that evaluates one final transport response.
    /// - Returns: A policy that returns the closure's decision for each response.
    public static func custom(
        validate: @escaping @Sendable (ResponseValidationContext) -> ResponseValidationResult,
    ) -> Self {
        Self(validate: validate)
    }

    package func validate(_ context: ResponseValidationContext) -> ResponseValidationResult {
        validateResponse(context)
    }
}

/// Describes a transport response rejected by the configured validation policy.
public struct ResponseValidationError: Error, Sendable {
    /// The HTTP response metadata that the policy rejected.
    public let httpResponse: HTTPResponse

    /// The configured prefix of the rejected response body, if retention was enabled.
    public let retainedBody: RetainedBody?

    /// The identity of the logical execution that received the rejected response.
    public let requestID: RequestID

    /// The optional diagnostic reason returned by the validation policy.
    public let reason: String?

    package init(
        httpResponse: HTTPResponse,
        retainedBody: RetainedBody?,
        requestID: RequestID,
        reason: String?,
    ) {
        self.httpResponse = httpResponse
        self.retainedBody = retainedBody
        self.requestID = requestID
        self.reason = reason
    }
}
