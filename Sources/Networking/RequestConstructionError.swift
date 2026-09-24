//
//  RequestConstructionError.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

/// Describes a library-owned failure while constructing a request before transport.
public struct RequestConstructionError: Error, Sendable, Equatable {
    /// Identifies the request construction failure.
    public enum Reason: Sendable, Equatable {
        /// A relative route requires a configured base URL.
        case relativeRouteRequiresBaseURL

        /// An absolute route does not contain a URL scheme.
        case missingURLScheme

        /// An absolute route uses a scheme other than HTTP or HTTPS.
        case unsupportedURLScheme(String)

        /// Foundation could not construct a usable HTTP or HTTPS URL from the route.
        case urlCompositionFailed

        /// Codable query data could not be serialized.
        case urlQueryEncoding(URLQueryEncodingError)

        /// Query layers could not be composed into a usable URL.
        case queryCompositionFailed

        /// The selected operation cannot safely execute the request body's representation.
        case unsupportedOperationBodyCombination
    }

    /// The logical execution identity assigned before route preflight.
    public let requestID: RequestID

    /// The reason request construction failed.
    public let reason: Reason

    package init(requestID: RequestID, reason: Reason) {
        self.requestID = requestID
        self.reason = reason
    }
}
