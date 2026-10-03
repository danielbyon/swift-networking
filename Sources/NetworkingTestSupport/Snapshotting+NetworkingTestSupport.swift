//
//  Snapshotting+NetworkingTestSupport.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking
import SnapshotTesting
import SnapshotTestingCustomDump

extension Snapshotting where Value == RecordedRequest, Format == String {
    /// A snapshot of one recorded transport attempt with run-specific values sanitized.
    ///
    /// Headers and query values stay redacted regardless of stability. Use
    /// `recordedRequest(.exact)` when a test needs exact request identities, timestamps, or paths.
    public static var recordedRequest: Snapshotting {
        recordedRequest(.sanitized)
    }

    /// A snapshot of one recorded transport attempt with the requested stability.
    ///
    /// - Parameters:
    ///   - stability: Whether run-specific values are sanitized or rendered exactly.
    ///   - additionalSensitiveHeaders: Extra HTTP field names whose values are redacted in both
    ///     stability modes, matching the additional headers production logging can redact.
    public static func recordedRequest(
        _ stability: SnapshotStability,
        additionalSensitiveHeaders: Set<String> = [],
    ) -> Snapshotting {
        Snapshotting<SnapshotRecordedRequest, String>.customDump.pullback {
            SnapshotRecordedRequest(
                $0,
                renderer: SnapshotProjectionRenderer(
                    stability: stability,
                    additionalSensitiveHeaders: additionalSensitiveHeaders,
                ),
            )
        }
    }
}

extension Snapshotting where Value == [AttemptMetrics], Format == String {
    /// A snapshot of an attempt history with run-specific values sanitized.
    public static var attemptHistory: Snapshotting {
        attemptHistory(.sanitized)
    }

    /// A snapshot of an attempt history with the requested stability.
    ///
    /// - Parameter stability: Whether run-specific values are sanitized or rendered exactly.
    public static func attemptHistory(
        _ stability: SnapshotStability,
    ) -> Snapshotting {
        Snapshotting<[SnapshotAttemptMetrics], String>.customDump.pullback { attempts in
            let renderer = SnapshotProjectionRenderer(
                stability: stability,
                requestIDAliases: RequestIDAliases(attempts.map(\.requestID)),
            )
            return attempts.map { SnapshotAttemptMetrics($0, renderer: renderer) }
        }
    }
}

extension Snapshotting where Value == [NetworkEvent], Format == String {
    /// A snapshot of a lifecycle event sequence with run-specific values sanitized.
    public static var networkEvents: Snapshotting {
        networkEvents(.sanitized)
    }

    /// A snapshot of a lifecycle event sequence with the requested stability.
    ///
    /// - Parameters:
    ///   - stability: Whether run-specific values are sanitized or rendered exactly.
    ///   - additionalSensitiveHeaders: Extra HTTP field names whose values are redacted in both
    ///     stability modes, matching the additional headers production logging can redact.
    public static func networkEvents(
        _ stability: SnapshotStability,
        additionalSensitiveHeaders: Set<String> = [],
    ) -> Snapshotting {
        Snapshotting<[SnapshotNetworkEvent], String>.customDump.pullback { events in
            let renderer = SnapshotProjectionRenderer(
                stability: stability,
                additionalSensitiveHeaders: additionalSensitiveHeaders,
                requestIDAliases: RequestIDAliases(events.map(\.projectionRequestID)),
            )
            return events.map { SnapshotNetworkEvent($0, renderer: renderer) }
        }
    }
}

extension Snapshotting {
    /// A snapshot of a decoded response with run-specific values sanitized.
    ///
    /// Downloaded values are projected from the package-internal storage location, so snapshotting
    /// a `Response<DownloadedFile>` never transfers file cleanup ownership to the caller.
    ///
    /// - Parameters:
    ///   - stability: Whether run-specific values are sanitized or rendered exactly.
    ///   - additionalSensitiveHeaders: Extra HTTP field names whose values are redacted in both
    ///     stability modes, matching the additional headers production logging can redact.
    public static func response<Output: Sendable>(
        _ stability: SnapshotStability = .sanitized,
        additionalSensitiveHeaders: Set<String> = [],
    ) -> Snapshotting where Value == Response<Output>, Format == String {
        Snapshotting<SnapshotResponse<Output>, String>.customDump.pullback { response in
            SnapshotResponse(
                response,
                renderer: SnapshotProjectionRenderer(
                    stability: stability,
                    additionalSensitiveHeaders: additionalSensitiveHeaders,
                    requestIDAliases: RequestIDAliases(
                        [response.requestID] + response.attempts.map(\.requestID),
                    ),
                ),
            )
        }
    }
}

extension Snapshotting where Value == JSONFixture, Format == String {
    /// A canonical snapshot of fixture content.
    ///
    /// The snapshot is pretty-printed with deterministically sorted object keys and preserves array
    /// order. Numbers keep the exact spelling from the source document, so arbitrary-precision
    /// decimals and arbitrary-size exponents survive the Foundation round trip.
    public static var json: Snapshotting {
        Snapshotting(pathExtension: "json", diffing: .lines) { fixture in
            fixture.canonicalJSON
        }
    }
}
