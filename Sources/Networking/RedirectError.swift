//
//  RedirectError.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

/// Describes a redirect chain that exceeded its configured per-attempt limit.
public enum RedirectError: Error, Sendable {
    /// The policy would follow a redirect after its per-attempt budget was exhausted.
    ///
    /// - Parameters:
    ///   - requestID: The logical request execution that exceeded its redirect budget.
    ///   - maximumRedirects: The number of redirects the policy allowed this transport attempt to follow.
    ///   - lastResponse: The redirect response that proposed the over-limit destination, when available.
    ///   - attempts: The transport attempt history through and including the task stopped by the limit.
    case tooManyRedirects(
        requestID: RequestID,
        maximumRedirects: UInt,
        lastResponse: HTTPResponse?,
        attempts: [AttemptMetrics],
    )
}
