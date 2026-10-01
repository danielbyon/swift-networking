//
//  NetworkTestDependencies.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking

/// Test-only execution dependencies for deterministic `NetworkClient.testing(...)` runs.
///
/// The bundle controls execution concerns that production configuration intentionally hides: the
/// monotonic sleep used between retry attempts, the wall-clock time used for lifecycle event
/// timestamps and `Retry-After` date resolution, and the jitter sample used by retry backoff
/// strategies. Production clients always use live behavior.
public struct NetworkTestDependencies: Sendable {
    /// Suspends for the supplied delay, or throws when the surrounding work is cancelled.
    ///
    /// Retry scheduling calls this closure only for non-zero delays and checks cancellation before
    /// and after the sleep, so implementations never need to wait for wall-clock time.
    public let sleep: @Sendable (Duration) async throws -> Void

    /// Returns the wall-clock time used for lifecycle event timestamps and HTTP-date retry delays.
    public let now: @Sendable () -> Date

    /// Returns the jitter sample in the range `0 ... 1` used by retry backoff strategies.
    public let randomUnit: @Sendable () -> Double

    /// Creates dependencies from explicit sleep, wall-clock, and jitter sources.
    ///
    /// - Parameters:
    ///   - sleep: The monotonic sleep used between retry attempts.
    ///   - now: The wall-clock source for event timestamps and HTTP-date retry delays.
    ///   - randomUnit: The jitter sample source for retry backoff strategies.
    public init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        randomUnit: @escaping @Sendable () -> Double,
    ) {
        self.sleep = sleep
        self.now = now
        self.randomUnit = randomUnit
    }

    /// Execution dependencies that match production behavior.
    ///
    /// Sleeps use a continuous clock, wall-clock time comes from `Date()`, and jitter uses
    /// `Double.random(in:)`.
    public static let live = Self(
        sleep: { delay in try await ContinuousClock().sleep(for: delay) },
        now: { Date() },
        randomUnit: { Double.random(in: 0 ... 1) },
    )

    /// Execution dependencies that never wait and return fixed wall-clock and jitter values.
    ///
    /// The sleeper returns immediately, so retry tests observe the resolved delays without waiting.
    /// Cancellation still prevents the next attempt because retry scheduling checks cancellation
    /// before and after every sleep.
    ///
    /// - Parameters:
    ///   - now: The fixed wall-clock time returned for every timestamp.
    ///   - randomUnit: The fixed jitter sample returned for every backoff calculation.
    /// - Returns: Dependencies that complete without wall-clock waiting.
    public static func deterministic(
        now: Date = Date(timeIntervalSince1970: 0),
        randomUnit: Double = 0.5,
    ) -> Self {
        Self(
            sleep: { _ in },
            now: { now },
            randomUnit: { randomUnit },
        )
    }
}
