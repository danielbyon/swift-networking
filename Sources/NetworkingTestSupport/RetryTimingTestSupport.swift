//
//  RetryTimingTestSupport.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking

/// Creates package-scoped retry timing dependencies for deterministic execution tests.
package enum RetryTimingTestSupport {
    /// Combines controlled sleep, wall-clock, and random sources for a NetworkClient test.
    package static func dependencies(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        randomUnit: @escaping @Sendable () -> Double,
    ) -> RetryTimingDependencies {
        RetryTimingDependencies(sleep: sleep, now: now, randomUnit: randomUnit)
    }
}
