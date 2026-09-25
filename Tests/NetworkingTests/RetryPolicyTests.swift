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
