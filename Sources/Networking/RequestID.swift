//
//  RequestID.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Identifies one logical execution of a request.
public struct RequestID: Hashable, Sendable, Codable {
    /// The UUID that backs this logical execution identity.
    public let rawValue: UUID

    /// Creates an execution identity from a UUID.
    ///
    /// - Parameter rawValue: The UUID to use as the identity.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Generates the identity assigned to each logical request execution.
public protocol RequestIDGenerator: Sendable {
    /// Generates one request identity synchronously.
    ///
    /// Implementations are responsible for deciding whether generated identities are unique.
    /// Networking does not enforce uniqueness.
    func generateRequestID() -> RequestID
}

/// Generates a UUID-backed identity for each logical request execution.
public struct UUIDRequestIDGenerator: RequestIDGenerator {
    /// Creates a UUID request identity generator.
    public init() {}

    /// Generates a new UUID-backed request identity.
    public func generateRequestID() -> RequestID {
        RequestID(rawValue: UUID())
    }
}
