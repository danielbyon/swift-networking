//
//  RetryTiming.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

package struct RetryTimingDependencies: Sendable {
    package let sleep: @Sendable (Duration) async throws -> Void
    package let now: @Sendable () -> Date
    package let randomUnit: @Sendable () -> Double

    package init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        randomUnit: @escaping @Sendable () -> Double,
    ) {
        self.sleep = sleep
        self.now = now
        self.randomUnit = randomUnit
    }

    package static var live: Self {
        Self(
            sleep: { delay in try await ContinuousClock().sleep(for: delay) },
            now: { Date() },
            randomUnit: { Double.random(in: 0 ... 1) },
        )
    }
}

package enum RetryTiming {
    private static let largestRepresentableDuration = Duration(secondsComponent: .max, attosecondsComponent: 0)

    package static func localDelay(
        strategy: RetryPolicy.BackoffStrategy,
        retryCount: UInt,
        randomUnit: @Sendable () -> Double,
    ) -> Duration {
        let baseDelay: Duration
        let jitter: RetryPolicy.Jitter
        let maximum: Duration

        switch strategy {
        case .immediate:
            return .zero
        case let .constant(delay, configuredJitter):
            baseDelay = delay
            jitter = configuredJitter
            maximum = largestRepresentableDuration
        case let .linear(initial, increment, configuredMaximum, configuredJitter):
            baseDelay = boundedDuration(
                seconds(initial) + seconds(increment) * Double(retryCount),
                maximum: configuredMaximum,
            )
            jitter = configuredJitter
            maximum = configuredMaximum
        case let .exponential(initial, multiplier, configuredMaximum, configuredJitter):
            let factor = pow(multiplier, Double(retryCount))
            let calculated = seconds(initial) * factor
            baseDelay = boundedDuration(calculated, maximum: configuredMaximum)
            jitter = configuredJitter
            maximum = configuredMaximum
        }

        let boundedBase = boundedDuration(seconds(baseDelay), maximum: maximum)
        guard jitter == .full else {
            return boundedBase
        }

        let sample = randomUnit()
        let unit = sample.isNaN ? 0 : min(1, max(0, sample))
        return boundedDuration(seconds(boundedBase) * unit, maximum: boundedBase)
    }

    package static func resolve(
        localDelay: Duration,
        retryAfterValue: String?,
        policy: RetryPolicy.RetryAfterPolicy,
        maximumServerDelay: Duration?,
        now: Date,
    ) -> Duration {
        let localDelay = boundedDuration(seconds(localDelay), maximum: largestRepresentableDuration)
        guard policy != .local,
              let parsedServerDelay = parseRetryAfter(retryAfterValue, now: now)
        else {
            return localDelay
        }

        let maximumServerDelay = maximumServerDelay ?? largestRepresentableDuration
        let serverDelay = boundedDuration(
            seconds(parsedServerDelay),
            maximum: maximumServerDelay,
        )

        return switch policy {
        case .local:
            localDelay
        case .server:
            serverDelay
        case .maximum:
            max(localDelay, serverDelay)
        }
    }

    package static func parseRetryAfter(_ value: String?, now: Date) -> Duration? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let scalars = value.unicodeScalars
        if scalars.allSatisfy({ (48 ... 57).contains($0.value) }) {
            var delaySeconds = 0.0
            for scalar in scalars {
                delaySeconds = delaySeconds * 10 + Double(scalar.value - 48)
                if !delaySeconds.isFinite {
                    delaySeconds = .greatestFiniteMagnitude
                    break
                }
            }
            return boundedDuration(delaySeconds, maximum: largestRepresentableDuration)
        }

        guard let retryDate = parseHTTPDate(value, relativeTo: now) else {
            return nil
        }

        let delaySeconds = retryDate.timeIntervalSince(now)
        guard delaySeconds > 0 else {
            return .zero
        }

        return boundedDuration(delaySeconds, maximum: largestRepresentableDuration)
    }

    package static func sleepIfNeeded(
        _ delay: Duration,
        using sleep: @Sendable (Duration) async throws -> Void,
    ) async throws {
        guard delay > .zero else {
            return
        }

        try Task.checkCancellation()
        try await sleep(delay)
        try Task.checkCancellation()
    }

    private static func parseHTTPDate(_ value: String, relativeTo now: Date) -> Date? {
        let formats: [(pattern: String, usesRFC850YearHandling: Bool)] = [
            (pattern: "EEE, dd MMM yyyy HH:mm:ss 'GMT'", usesRFC850YearHandling: false),
            (pattern: "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", usesRFC850YearHandling: true),
            (pattern: "EEE MMM d HH:mm:ss yyyy", usesRFC850YearHandling: false),
        ]
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.isLenient = false
            formatter.dateFormat = format.pattern

            if format.usesRFC850YearHandling {
                formatter.twoDigitStartDate = calendar.date(byAdding: .year, value: -50, to: now)
            }

            guard let date = formatter.date(from: value) else {
                continue
            }
            guard format.usesRFC850YearHandling else {
                return date
            }
            guard let fiftyYearsAhead = calendar.date(byAdding: .year, value: 50, to: now),
                  date > fiftyYearsAhead,
                  let previousCentury = calendar.date(byAdding: .year, value: -100, to: date)
            else {
                return date
            }

            return previousCentury
        }

        return nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func boundedDuration(_ seconds: Double, maximum: Duration) -> Duration {
        let maximumSeconds = Self.seconds(maximum)
        guard maximumSeconds > 0, seconds > 0 else {
            return .zero
        }
        guard !seconds.isNaN else {
            return .zero
        }
        guard seconds < maximumSeconds else {
            return maximum
        }

        return .seconds(seconds)
    }
}
