//
//  RetryPolicyTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct RetryPolicyTests {
    @Test("Retry policy defaults disable retries and expose the approved built-in eligibility")
    func defaultsExposeBuiltInEligibility() {
        let policy = RetryPolicy()

        #expect(policy.maximumRetries == 0)
        #expect(policy.backoffStrategy == .immediate)
        #expect(policy.retryAfterPolicy == .server)
        #expect(policy.maximumRetryAfterDelay == .seconds(60))
        #expect(policy.retryableMethods == Set([.get, .head, .options, .trace, .put, .delete]))
        #expect(policy.retryableStatusCodes == Set([408, 429, 500, 502, 503, 504]))
        #expect(
            policy.retryableURLErrorCodes == Set([
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
            ]),
        )
    }

    @Test("Backoff strategies use retry count and safely cap finite overflow")
    func backoffStrategiesCalculateBoundedDelays() {
        let linear = RetryPolicy.BackoffStrategy.linear(
            initial: .seconds(2),
            increment: .seconds(3),
            maximum: .seconds(8),
        )
        #expect(RetryTiming.localDelay(strategy: linear, retryCount: 0, randomUnit: { 0.5 }) == .seconds(2))
        #expect(RetryTiming.localDelay(strategy: linear, retryCount: 1, randomUnit: { 0.5 }) == .seconds(5))
        #expect(RetryTiming.localDelay(strategy: linear, retryCount: 2, randomUnit: { 0.5 }) == .seconds(8))

        let exponential = RetryPolicy.BackoffStrategy.exponential(
            initial: .seconds(2),
            maximum: .seconds(16),
        )
        #expect(RetryTiming.localDelay(strategy: exponential, retryCount: 0, randomUnit: { 0.5 }) == .seconds(1))
        #expect(RetryTiming.localDelay(strategy: exponential, retryCount: 1, randomUnit: { 0.5 }) == .seconds(2))
        #expect(RetryTiming.localDelay(strategy: exponential, retryCount: 2, randomUnit: { 0.5 }) == .seconds(4))

        let linearOverflow = RetryPolicy.BackoffStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(1),
            maximum: .seconds(9),
        )
        let exponentialOverflow = RetryPolicy.BackoffStrategy.exponential(
            initial: .seconds(1),
            multiplier: 2,
            maximum: .seconds(9),
            jitter: .none,
        )
        #expect(RetryTiming.localDelay(strategy: linearOverflow, retryCount: .max, randomUnit: { 0.5 }) == .seconds(9))
        #expect(
            RetryTiming.localDelay(strategy: exponentialOverflow, retryCount: .max, randomUnit: { 0.5 }) == .seconds(9),
        )
    }

    @Test("Strategy jitter defaults can be overridden where jitter is configurable")
    func strategyJitterDefaultsAndOverrides() {
        let constantDefault = RetryPolicy.BackoffStrategy.constant(.seconds(8))
        let constantFull = RetryPolicy.BackoffStrategy.constant(.seconds(8), jitter: .full)
        let linearDefault = RetryPolicy.BackoffStrategy.linear(
            initial: .seconds(2),
            increment: .seconds(2),
            maximum: .seconds(12),
        )
        let linearFull = RetryPolicy.BackoffStrategy.linear(
            initial: .seconds(2),
            increment: .seconds(2),
            maximum: .seconds(12),
            jitter: .full,
        )
        let exponentialNone = RetryPolicy.BackoffStrategy.exponential(
            initial: .seconds(8),
            multiplier: 2,
            maximum: .seconds(12),
            jitter: .none,
        )

        #expect(RetryTiming.localDelay(strategy: .immediate, retryCount: 3, randomUnit: { 1 }) == .zero)
        #expect(RetryTiming.localDelay(strategy: constantDefault, retryCount: 0, randomUnit: { 0.25 }) == .seconds(8))
        #expect(RetryTiming.localDelay(strategy: constantFull, retryCount: 0, randomUnit: { 0 }) == .zero)
        #expect(RetryTiming.localDelay(strategy: constantFull, retryCount: 0, randomUnit: { 0.25 }) == .seconds(2))
        #expect(RetryTiming.localDelay(strategy: constantFull, retryCount: 0, randomUnit: { 1 }) == .seconds(8))
        #expect(RetryTiming.localDelay(strategy: linearDefault, retryCount: 1, randomUnit: { 0.25 }) == .seconds(4))
        #expect(RetryTiming.localDelay(strategy: linearFull, retryCount: 1, randomUnit: { 0.25 }) == .seconds(1))
        #expect(RetryTiming.localDelay(strategy: exponentialNone, retryCount: 0, randomUnit: { 0.25 }) == .seconds(8))
        #expect(
            RetryTiming.localDelay(
                strategy: .constant(.zero, jitter: .full),
                retryCount: 0,
                randomUnit: { 1 },
            ) == .zero,
        )
    }

    @Test("Retry-After parses delta seconds and every HTTP-date format")
    func retryAfterParsesDeltaSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 0)
        let dates = [
            "Thu, 01 Jan 1970 00:00:10 GMT",
            "Thursday, 01-Jan-70 00:00:10 GMT",
            "Thu Jan  1 00:00:10 1970",
        ]

        #expect(RetryTiming.parseRetryAfter("7", now: now) == .seconds(7))
        for value in dates {
            #expect(RetryTiming.parseRetryAfter(value, now: now) == .seconds(10))
        }
        #expect(RetryTiming.parseRetryAfter("Wed, 31 Dec 1969 23:59:59 GMT", now: now) == .zero)
        #expect(RetryTiming.parseRetryAfter("not-a-date", now: now) == nil)
    }

    @Test("Four-digit HTTP dates more than 50 years ahead remain future server delays")
    func fourDigitHTTPDatesBeyondFiftyYearsRemainFuture() {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let futureDates = [
            "Mon, 01 Jan 2080 00:00:10 GMT",
            "Mon Jan  1 00:00:10 2080",
        ]

        for value in futureDates {
            #expect(RetryTiming.parseRetryAfter(value, now: now).map { $0 > .zero } == true)
            #expect(
                RetryTiming.resolve(
                    localDelay: .seconds(3),
                    retryAfterValue: value,
                    policy: .server,
                    maximumServerDelay: .seconds(60),
                    now: now,
                ) == .seconds(60),
            )
        }
    }

    @Test("RFC 850 dates use the two-digit year 50-year window")
    func rfc850DatesUseFiftyYearWindow() {
        let now = Date(timeIntervalSince1970: 1_767_225_600)

        #expect(
            RetryTiming.parseRetryAfter("Tuesday, 01-Jan-75 00:00:10 GMT", now: now)
                .map { $0 > .zero } == true,
        )
        #expect(RetryTiming.parseRetryAfter("Monday, 01-Jan-80 00:00:10 GMT", now: now) == .zero)
    }

    @Test("Retry-After cap and precedence resolve after local jitter")
    func retryAfterCapAndPrecedence() {
        let now = Date(timeIntervalSince1970: 0)
        let localDelay = Duration.seconds(10)

        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "120",
                policy: .server,
                maximumServerDelay: .seconds(60),
                now: now,
            ) == .seconds(60),
        )
        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "120",
                policy: .server,
                maximumServerDelay: nil,
                now: now,
            ) == .seconds(120),
        )
        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "5",
                policy: .local,
                maximumServerDelay: .seconds(60),
                now: now,
            ) == localDelay,
        )
        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "5",
                policy: .server,
                maximumServerDelay: .seconds(60),
                now: now,
            ) == .seconds(5),
        )
        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "15",
                policy: .maximum,
                maximumServerDelay: .seconds(60),
                now: now,
            ) == .seconds(15),
        )
        #expect(
            RetryTiming.resolve(
                localDelay: localDelay,
                retryAfterValue: "invalid",
                policy: .server,
                maximumServerDelay: .seconds(60),
                now: now,
            ) == localDelay,
        )
    }

    @Test("Endpoint and request copies preserve replacement retry policies")
    func endpointAndRequestCopiesPreserveRetryPolicy() throws {
        let url = try #require(URL(string: "https://example.com/retry"))
        let validationPolicy = ResponseValidationPolicy.custom { _ in .accept }
        let policy = RetryPolicy { $0.maximumRetries = 4 }
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        .retryPolicy(policy)

        let endpointCopies: [Endpoint<Never, Never, Data>] = [
            endpoint.headers(HTTPFields()),
            endpoint.headers { _ in HTTPFields() },
            endpoint.header(.accept, "endpoint"),
            endpoint.jsonEncoderConfiguration { $0.outputFormatting = .sortedKeys },
            endpoint.jsonDecoderConfiguration { $0.keyDecodingStrategy = .convertFromSnakeCase },
            endpoint.validationPolicy(validationPolicy),
            endpoint.successfulResponseBodyRetentionPolicy(.none),
            endpoint.validationErrorBodyRetentionPolicy(.unlimited),
        ]

        for copy in endpointCopies {
            #expect(copy.retryPolicy?.maximumRetries == 4)
        }

        let inputEndpoint = Endpoint<Int, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: 0) { _ in url },
            response: .data,
        )
        .headers { _ in HTTPFields() }
        .retryPolicy(policy)
        #expect(inputEndpoint.header(.accept, "input").retryPolicy?.maximumRetries == 4)

        let bodyEncoding = BodyEncoding<String>.custom { Data($0.utf8) }
        let bodylessInputRequest = Request(
            endpoint: inputEndpoint,
            input: 42,
        )
        let bodyfulEndpoint = Endpoint<Never, String, Data>.data(
            method: .post,
            route: .absolute(url),
            body: bodyEncoding,
            response: .data,
        )
        .retryPolicy(policy)
        let bodyfulRequest = Request(endpoint: bodyfulEndpoint, body: "payload")
        let bodyfulInputEndpoint = Endpoint<Int, String, Data>.data(
            method: .post,
            route: .absolute(forInput: 0) { _ in url },
            body: bodyEncoding,
            response: .data,
        )
        .retryPolicy(policy)
        let bodyfulInputRequest = Request(endpoint: bodyfulInputEndpoint, input: 42, body: "payload")
        #expect(bodylessInputRequest.retryPolicy?.maximumRetries == 4)
        #expect(bodyfulRequest.retryPolicy?.maximumRetries == 4)
        #expect(bodyfulInputRequest.retryPolicy?.maximumRetries == 4)

        let request = Request(endpoint: endpoint).retryPolicy(policy)
        let requestCopies: [Request<Data>] = [
            request.context(RetryTraceKey.self, value: "trace-1"),
            request.queryItems([URLQueryItem(name: "page", value: "2")]),
            request.headers(HTTPFields()),
            request.header(.accept, "request"),
            request.validationPolicy(validationPolicy),
            request.successfulResponseBodyRetentionPolicy(.none),
            request.validationErrorBodyRetentionPolicy(.unlimited),
        ]

        for copy in requestCopies {
            #expect(copy.retryPolicy?.maximumRetries == 4)
        }

        let builderEndpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        .retryPolicy { $0.maximumRetries = 5 }
        #expect(builderEndpoint.retryPolicy?.maximumRetries == 5)
        #expect(builderEndpoint.retryPolicy?.retryableMethods == RetryPolicy().retryableMethods)

        let builderRequest = Request(endpoint: endpoint)
            .retryPolicy { $0.maximumRetries = 6 }
        #expect(builderRequest.retryPolicy?.maximumRetries == 6)
        #expect(builderRequest.retryPolicy?.retryableMethods == RetryPolicy().retryableMethods)
    }
}

private enum RetryTraceKey: RequestContextKey {
    typealias Value = String
}
