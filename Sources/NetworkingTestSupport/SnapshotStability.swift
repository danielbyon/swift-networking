//
//  SnapshotStability.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking

/// Selects whether a snapshot replaces run-specific values with stable placeholders.
///
/// Stability never controls privacy. Sensitive header and query values are redacted in both modes,
/// so opting into exact values cannot expose credentials or payload locations.
public enum SnapshotStability: Sendable, Equatable, Hashable {
    /// Replaces request identities, timestamps, durations, and generated locations with placeholders.
    case sanitized

    /// Renders request identities, timestamps, durations, and locations exactly as recorded.
    case exact
}

/// The stable text replacements used by sanitized snapshots.
enum SnapshotPlaceholder {
    static let requestID = "<request-id>"
    static let timestamp = "<timestamp>"
    static let duration = "<duration>"
    static let location = "<generated-location>"
    static let absent = "<none>"
    static let present = "<present>"

    /// The numbered placeholder used when one snapshot contains several request identities.
    static func requestIDAlias(_ ordinal: Int) -> String {
        "<request-id-" + String(ordinal) + ">"
    }
}

/// Deterministic placeholders for the request identities that appear in one snapshot.
///
/// Identities are numbered in the order they first appear in the snapshotted content, so the same
/// identity relationships survive every run without depending on the generated identifier values.
/// A snapshot that contains only one identity needs no disambiguation, so it keeps the plain
/// placeholder instead of a numbered alias.
struct RequestIDAliases: Sendable, Equatable {
    /// No aliases; every sanitized identity renders as the plain placeholder.
    static let none = RequestIDAliases(aliases: [:])

    private let aliases: [RequestID: String]

    /// Creates aliases for the distinct identities a snapshot renders.
    ///
    /// - Parameter requestIDs: Every identity the snapshot can render, listed in the order the
    ///   snapshot renders them.
    init(_ requestIDs: [RequestID]) {
        var ordered: [RequestID] = []
        for requestID in requestIDs where !ordered.contains(requestID) {
            ordered.append(requestID)
        }

        guard ordered.count > 1 else {
            self = .none
            return
        }

        aliases = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map { index, requestID in
                (requestID, SnapshotPlaceholder.requestIDAlias(index + 1))
            },
        )
    }

    private init(aliases: [RequestID: String]) {
        self.aliases = aliases
    }

    /// Returns the alias for the supplied identity, or nil when it has no dedicated alias.
    func alias(for requestID: RequestID) -> String? {
        aliases[requestID]
    }
}

/// Renders individual values with the stability a snapshot requested.
///
/// Free-form text that can embed request details, such as attempt diagnostic reasons and thrown
/// errors, is projected to a bounded identity in both modes because no redaction can prove it safe.
struct SnapshotProjectionRenderer: Sendable {
    let stability: SnapshotStability

    private let additionalSensitiveHeaders: Set<String>
    private let requestIDAliases: RequestIDAliases

    /// Creates a renderer for one snapshot.
    ///
    /// - Parameters:
    ///   - stability: Whether run-specific values are sanitized or rendered exactly.
    ///   - additionalSensitiveHeaders: Extra HTTP field names whose values are redacted in both
    ///     modes, in addition to the names that production diagnostics always redact.
    ///   - requestIDAliases: The aliases used for sanitized request identities.
    init(
        stability: SnapshotStability,
        additionalSensitiveHeaders: Set<String> = [],
        requestIDAliases: RequestIDAliases = .none,
    ) {
        self.stability = stability
        self.additionalSensitiveHeaders = additionalSensitiveHeaders
        self.requestIDAliases = requestIDAliases
    }

    /// Every HTTP field name whose value is redacted in both stability modes.
    var sensitiveHeaderNames: Set<String> {
        NetworkPrivacySanitizer.mandatorySensitiveHeaderNames
            .union(additionalSensitiveHeaders.map { $0.lowercased() })
    }

    func requestID(_ value: RequestID) -> String {
        switch stability {
        case .sanitized:
            requestIDAliases.alias(for: value) ?? SnapshotPlaceholder.requestID
        case .exact:
            value.rawValue.uuidString
        }
    }

    func timestamp(_ value: Date) -> String {
        switch stability {
        case .sanitized:
            SnapshotPlaceholder.timestamp
        case .exact:
            Self.exactTimestamp(value)
        }
    }

    func duration(_ value: Duration) -> String {
        switch stability {
        case .sanitized:
            SnapshotPlaceholder.duration
        case .exact:
            Self.exactDuration(value)
        }
    }

    func location(_ url: URL) -> String {
        switch stability {
        case .sanitized:
            SnapshotPlaceholder.location
        case .exact:
            url.path
        }
    }

    /// Reports only whether a free-form diagnostic is present, never its text.
    func diagnosticReason(_ value: String?) -> String {
        value == nil ? SnapshotPlaceholder.absent : SnapshotPlaceholder.present
    }

    /// Reports only whether Foundation task metrics are present, never their contents.
    func rawTaskMetrics(_ value: URLSessionTaskMetrics?) -> String {
        value == nil ? SnapshotPlaceholder.absent : SnapshotPlaceholder.present
    }

    /// Identifies a thrown error by dynamic type without rendering any secret-bearing description.
    func errorIdentity(_ error: any Error) -> String {
        String(describing: Swift.type(of: error))
    }

    /// Renders a duration in seconds with the full attosecond resolution of its components.
    ///
    /// The components are formatted directly instead of being converted to a floating-point
    /// number, so sub-nanosecond differences stay visible and large durations keep every digit.
    private static func exactDuration(_ value: Duration) -> String {
        let components = value.components
        let sign = components.seconds < 0 || components.attoseconds < 0 ? "-" : ""
        let attoseconds = String(components.attoseconds.magnitude)
        var fraction = String(repeating: "0", count: max(0, 18 - attoseconds.count)) + attoseconds
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }

        let seconds = String(components.seconds.magnitude)

        return fraction.isEmpty ? sign + seconds + "s" : sign + seconds + "." + fraction + "s"
    }

    /// Renders a date for an exact snapshot.
    ///
    /// The readable part is a UTC ISO-8601 timestamp with nine fractional digits derived from the
    /// recorded value's reference-date interval, so it is never narrowed by the Unix epoch offset.
    /// Nine digits still cannot represent every distinct Date, so the full reference interval is
    /// appended in Swift's round-trippable decimal form. Two recorded Dates that are not equal
    /// therefore always render differently, and the recorded value can be recovered from the
    /// snapshot text.
    private static func exactTimestamp(_ value: Date) -> String {
        let referenceInterval = value.timeIntervalSinceReferenceDate
        var wholeSeconds = referenceInterval.rounded(.down)
        var nanoseconds = Int(((referenceInterval - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            nanoseconds = 0
            wholeSeconds += 1
        }

        let digits = String(nanoseconds)
        let fraction = String(repeating: "0", count: 9 - digits.count) + digits
        let base = Date(timeIntervalSinceReferenceDate: wholeSeconds).formatted(.iso8601)
        let readable = String(base.dropLast()) + "." + fraction + "Z"

        // Equal instants must not render two different strings, so negative zero becomes zero.
        let lossless = referenceInterval == 0 ? "0" : String(referenceInterval)

        return readable + " (reference interval: " + lossless + ")"
    }
}
