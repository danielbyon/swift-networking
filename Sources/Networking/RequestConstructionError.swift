//
//  RequestConstructionError.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

/// Describes a library-owned failure while resolving a request route before transport.
public struct RequestConstructionError: Error, Sendable, Equatable {
    /// Identifies the route resolution failure.
    public enum Reason: Sendable, Equatable {
        /// A relative route requires a configured base URL.
        case relativeRouteRequiresBaseURL

        /// An absolute route does not contain a URL scheme.
        case missingURLScheme

        /// An absolute route uses a scheme other than HTTP or HTTPS.
        case unsupportedURLScheme(String)

        /// Foundation could not construct a usable HTTP or HTTPS URL from the route.
        case urlCompositionFailed
    }

    /// The logical execution identity assigned before route preflight.
    public let requestID: RequestID

    /// The reason route construction failed.
    public let reason: Reason

    package init(requestID: RequestID, reason: Reason) {
        self.requestID = requestID
        self.reason = reason
    }
}
