//
//  RedirectPolicy.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Selects whether URLSession follows each proposed HTTP redirect.
///
/// A redirect policy also bounds how many redirects one transport attempt may follow. Redirects
/// remain part of the URLSession task that received the initial request.
public struct RedirectPolicy: Sendable {
    /// The decision returned for one proposed redirect.
    public enum Decision: Sendable, Equatable {
        /// Allows URLSession to continue with its proposed redirected request.
        case follow

        /// Keeps the redirect response as the result of the current transport attempt.
        case reject
    }

    /// The request and execution metadata supplied to a custom redirect decision.
    public struct Context: Sendable {
        /// The Foundation request currently being evaluated for redirection.
        public let currentRequest: URLRequest

        /// The request Foundation proposes using if the redirect is followed.
        public let proposedRequest: URLRequest

        /// The HTTP response that proposed the redirect.
        public let httpResponse: HTTPResponse

        /// The identity shared by all attempts in the logical execution.
        public let requestID: RequestID

        /// Typed metadata associated with the logical request.
        public let requestContext: RequestContext

        /// The one-based transport attempt containing this redirect.
        public let attemptNumber: UInt

        /// The one-based redirect proposal number within this transport attempt.
        public let redirectOrdinal: UInt

        package init(
            currentRequest: URLRequest,
            proposedRequest: URLRequest,
            httpResponse: HTTPResponse,
            requestID: RequestID,
            requestContext: RequestContext,
            attemptNumber: UInt,
            redirectOrdinal: UInt,
        ) {
            self.currentRequest = currentRequest
            self.proposedRequest = proposedRequest
            self.httpResponse = httpResponse
            self.requestID = requestID
            self.requestContext = requestContext
            self.attemptNumber = attemptNumber
            self.redirectOrdinal = redirectOrdinal
        }
    }

    /// The maximum number of redirects one transport attempt may follow.
    public let maximumRedirects: UInt

    private let decide: @Sendable (Context) -> Decision

    /// Follows redirects, up to the default limit of ten per transport attempt.
    public static let follow = follow(maximumRedirects: 10)

    /// Creates a follow policy with a custom per-attempt redirect limit.
    ///
    /// - Parameter maximumRedirects: The maximum number of redirects to follow in one transport attempt.
    /// - Returns: A policy that follows redirects within the configured limit.
    public static func follow(maximumRedirects: UInt) -> Self {
        Self(maximumRedirects: maximumRedirects) { _ in .follow }
    }

    /// Rejects redirects, preserving each redirect response as the attempt's final response.
    public static let reject = reject(maximumRedirects: 10)

    /// Creates a reject policy with an explicit per-attempt redirect limit.
    ///
    /// The limit does not cause an error because this policy never follows a redirect.
    ///
    /// - Parameter maximumRedirects: The limit carried by this replacement policy.
    /// - Returns: A policy that rejects every redirect proposal.
    public static func reject(maximumRedirects: UInt) -> Self {
        Self(maximumRedirects: maximumRedirects) { _ in .reject }
    }

    /// Follows redirects only when source and destination have the same normalized origin.
    public static let sameOriginOnly = sameOriginOnly(maximumRedirects: 10)

    /// Creates a same-origin policy with a custom per-attempt redirect limit.
    ///
    /// Origins compare scheme and host without regard to case and compare effective ports,
    /// treating omitted HTTP and HTTPS ports as 80 and 443. A missing origin component or an
    /// unsupported scheme without an explicit port causes the proposal to be rejected.
    ///
    /// - Parameter maximumRedirects: The maximum number of redirects to follow in one transport attempt.
    /// - Returns: A policy that follows only same-origin proposals within the configured limit.
    public static func sameOriginOnly(maximumRedirects: UInt) -> Self {
        Self(maximumRedirects: maximumRedirects) { context in
            isSameOrigin(context.currentRequest.url, context.proposedRequest.url) ? .follow : .reject
        }
    }

    /// Creates a policy from a synchronous, nonthrowing redirect decision.
    ///
    /// - Parameters:
    ///   - maximumRedirects: The maximum number of redirects to follow in one transport attempt.
    ///   - decide: A Sendable closure that chooses whether URLSession follows each proposal.
    /// - Returns: A policy that uses the closure's decision within the configured limit.
    public static func custom(
        maximumRedirects: UInt = 10,
        decide: @escaping @Sendable (Context) -> Decision,
    ) -> Self {
        Self(maximumRedirects: maximumRedirects, decide: decide)
    }

    package func decision(for context: Context) -> Decision {
        decide(context)
    }

    private static func isSameOrigin(_ sourceURL: URL?, _ destinationURL: URL?) -> Bool {
        guard let source = Origin(url: sourceURL),
              let destination = Origin(url: destinationURL)
        else {
            return false
        }

        return source == destination
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(url: URL?) {
            guard let url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let normalizedScheme = components.scheme?.lowercased(),
                  let normalizedHost = components.host?.lowercased(),
                  normalizedScheme.isEmpty == false,
                  normalizedHost.isEmpty == false,
                  let effectivePort = components.port ?? Self.defaultPort(for: normalizedScheme)
            else {
                return nil
            }

            scheme = normalizedScheme
            host = normalizedHost
            port = effectivePort
        }

        private static func defaultPort(for scheme: String) -> Int? {
            switch scheme {
            case "http":
                80
            case "https":
                443
            default:
                nil
            }
        }
    }
}
