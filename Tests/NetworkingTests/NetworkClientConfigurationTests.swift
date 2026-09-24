//
//  NetworkClientConfigurationTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct NetworkClientConfigurationTests {
    @Test("Default session policy preserves Foundation defaults except ambient stores")
    func defaultSessionPolicyPreservesFoundationDefaultsExceptAmbientStores() {
        let foundationDefaults = URLSessionConfiguration.default
        let configuration = makeForegroundURLSessionConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == foundationDefaults.timeoutIntervalForRequest)
        #expect(configuration.timeoutIntervalForResource == foundationDefaults.timeoutIntervalForResource)
        #expect(configuration.requestCachePolicy == foundationDefaults.requestCachePolicy)
        #expect(configuration.waitsForConnectivity == foundationDefaults.waitsForConnectivity)
        #expect(configuration.allowsExpensiveNetworkAccess == foundationDefaults.allowsExpensiveNetworkAccess)
        #expect(configuration.allowsConstrainedNetworkAccess == foundationDefaults.allowsConstrainedNetworkAccess)
        #expect(configuration.allowsCellularAccess == foundationDefaults.allowsCellularAccess)
    }

    @Test("Configured client policies map to the owned session configuration")
    func configuredPoliciesMapToSessionConfiguration() {
        let cache = URLCache(memoryCapacity: 1_024, diskCapacity: 0, diskPath: nil)
        let cookies = HTTPCookieStorage.shared
        let clientConfiguration = NetworkClient.Configuration()
            .withURLCache(cache)
            .withHTTPCookieStorage(cookies)
            .withRequestTimeout(.milliseconds(2_500))
            .withResourceTimeout(.seconds(90))
            .withWaitsForConnectivity(true)
            .withAllowsExpensiveNetworkAccess(false)
            .withAllowsConstrainedNetworkAccess(false)
            .withAllowsCellularAccess(false)
            .withCachePolicy(.reloadIgnoringLocalCacheData)

        let sessionConfiguration = makeForegroundURLSessionConfiguration(configuration: clientConfiguration)

        #expect(sessionConfiguration.urlCache === cache)
        #expect(sessionConfiguration.httpCookieStorage === cookies)
        #expect(sessionConfiguration.urlCredentialStorage == nil)
        #expect(sessionConfiguration.timeoutIntervalForRequest == 2.5)
        #expect(sessionConfiguration.timeoutIntervalForResource == 90)
        #expect(sessionConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(sessionConfiguration.waitsForConnectivity)
        #expect(!sessionConfiguration.allowsExpensiveNetworkAccess)
        #expect(!sessionConfiguration.allowsConstrainedNetworkAccess)
        #expect(!sessionConfiguration.allowsCellularAccess)
    }

    @Test("Configuration modifiers preserve unrelated client policies")
    func configurationModifiersPreserveUnrelatedClientPolicies() throws {
        let baseURL = try #require(URL(string: "https://example.com/api"))
        let cache = URLCache(memoryCapacity: 1_024, diskCapacity: 0, diskPath: nil)
        let cookies = HTTPCookieStorage.shared
        let configuration = NetworkClient.Configuration(baseURL: baseURL)
            .withURLCache(cache)
            .withHTTPCookieStorage(cookies)
            .withRequestTimeout(.seconds(5))
            .withResourceTimeout(.seconds(60))
            .withWaitsForConnectivity(true)
            .withAllowsExpensiveNetworkAccess(false)
            .withAllowsConstrainedNetworkAccess(false)
            .withAllowsCellularAccess(false)
            .withCachePolicy(.reloadIgnoringLocalCacheData)
            .withAssumesHTTP3Capable(true)

        let copies: [(NetworkClient.Configuration, ModifiedPolicy)] = [
            (configuration.withDefaultHeaders(HTTPFields()), .none),
            (configuration.withDefaultQueryItems([URLQueryItem(name: "new", value: "value")]), .none),
            (configuration.withURLQueryEncoderConfiguration(.init(arrayStrategy: .brackets)), .none),
            (configuration.withRequestIDGenerator(UUIDRequestIDGenerator()), .none),
            (configuration.withURLCache(nil), .urlCache),
            (configuration.withHTTPCookieStorage(nil), .cookieStorage),
            (configuration.withRequestTimeout(nil), .requestTimeout),
            (configuration.withResourceTimeout(nil), .resourceTimeout),
            (configuration.withWaitsForConnectivity(false), .waitsForConnectivity),
            (configuration.withAllowsExpensiveNetworkAccess(true), .expensiveAccess),
            (configuration.withAllowsConstrainedNetworkAccess(true), .constrainedAccess),
            (configuration.withAllowsCellularAccess(true), .cellularAccess),
            (configuration.withCachePolicy(.useProtocolCachePolicy), .cachePolicy),
            (configuration.withAssumesHTTP3Capable(false), .http3Preference),
        ]

        for (copy, modifiedPolicy) in copies {
            expectUnmodifiedPolicies(in: copy, matching: configuration, except: modifiedPolicy)
        }
    }

    @Test("Request and resource timeouts require positive durations")
    func nonPositiveTimeoutsAreRejected() throws {
        let cases: [(NetworkClient.Configuration, NetworkClient.ConfigurationError.Failure)] = [
            (.init().withRequestTimeout(.zero), .requestTimeout),
            (.init().withRequestTimeout(.seconds(-1)), .requestTimeout),
            (.init().withResourceTimeout(.zero), .resourceTimeout),
            (.init().withResourceTimeout(.seconds(-1)), .resourceTimeout),
        ]

        for (configuration, expectedFailure) in cases {
            try expectConfigurationFailures([expectedFailure], from: configuration)
        }
    }

    @Test("Configuration validation aggregates base URL and timeout failures in contract order")
    func validationAggregatesBaseURLAndTimeoutFailuresInContractOrder() throws {
        let baseURL = try #require(URL(string: "ftp://example.com/api?key=value#section"))
        let configuration = NetworkClient.Configuration(baseURL: baseURL)
            .withRequestTimeout(.zero)
            .withResourceTimeout(.seconds(-1))

        try expectConfigurationFailures(
            [
                .baseURLScheme,
                .baseURLQuery,
                .baseURLFragment,
                .requestTimeout,
                .resourceTimeout,
            ],
            from: configuration,
        )
    }

    @Test("Timeout validation runs without a base URL and accepts nil or positive values")
    func timeoutValidationRunsWithoutBaseURLAndAcceptsValidValues() throws {
        _ = try NetworkClient(configuration: .init())
        _ = try NetworkClient(
            configuration: .init()
                .withRequestTimeout(.milliseconds(1_500))
                .withResourceTimeout(.seconds(30)),
        )
        let invalidTimeouts = NetworkClient.Configuration()
            .withRequestTimeout(.zero)
            .withResourceTimeout(.seconds(-1))

        try expectConfigurationFailures([.requestTimeout, .resourceTimeout], from: invalidTimeouts)
    }

    @Test("HTTP/3 preference is applied to an outgoing URLRequest only when configured")
    func http3PreferenceAppliesOnlyWhenConfigured() throws {
        let url = try #require(URL(string: "https://example.com/resource"))
        let httpRequest = HTTPRequest(method: .get, url: url)
        let foundationRequest = try #require(URLRequest(httpRequest: httpRequest))
        let unconfiguredRequest = try #require(makeURLRequest(httpRequest, assumesHTTP3Capable: nil))

        #expect(unconfiguredRequest.assumesHTTP3Capable == foundationRequest.assumesHTTP3Capable)

        let capableRequest = try #require(makeURLRequest(httpRequest, assumesHTTP3Capable: true))
        let incapableRequest = try #require(makeURLRequest(httpRequest, assumesHTTP3Capable: false))

        #expect(capableRequest.assumesHTTP3Capable)
        #expect(!incapableRequest.assumesHTTP3Capable)
    }
}

private enum ModifiedPolicy: Equatable {
    case none
    case urlCache
    case cookieStorage
    case requestTimeout
    case resourceTimeout
    case waitsForConnectivity
    case expensiveAccess
    case constrainedAccess
    case cellularAccess
    case cachePolicy
    case http3Preference
}

private func expectUnmodifiedPolicies(
    in actual: NetworkClient.Configuration,
    matching expected: NetworkClient.Configuration,
    except modifiedPolicy: ModifiedPolicy,
) {
    if modifiedPolicy != .urlCache {
        #expect(actual.urlCache === expected.urlCache)
    }
    if modifiedPolicy != .cookieStorage {
        #expect(actual.httpCookieStorage === expected.httpCookieStorage)
    }
    if modifiedPolicy != .requestTimeout {
        #expect(actual.requestTimeout == expected.requestTimeout)
    }
    if modifiedPolicy != .resourceTimeout {
        #expect(actual.resourceTimeout == expected.resourceTimeout)
    }
    if modifiedPolicy != .waitsForConnectivity {
        #expect(actual.waitsForConnectivity == expected.waitsForConnectivity)
    }
    if modifiedPolicy != .expensiveAccess {
        #expect(actual.allowsExpensiveNetworkAccess == expected.allowsExpensiveNetworkAccess)
    }
    if modifiedPolicy != .constrainedAccess {
        #expect(actual.allowsConstrainedNetworkAccess == expected.allowsConstrainedNetworkAccess)
    }
    if modifiedPolicy != .cellularAccess {
        #expect(actual.allowsCellularAccess == expected.allowsCellularAccess)
    }
    if modifiedPolicy != .cachePolicy {
        #expect(actual.cachePolicy == expected.cachePolicy)
    }
    if modifiedPolicy != .http3Preference {
        #expect(actual.assumesHTTP3Capable == expected.assumesHTTP3Capable)
    }
}

private func expectConfigurationFailures(
    _ expectedFailures: [NetworkClient.ConfigurationError.Failure],
    from configuration: NetworkClient.Configuration,
) throws {
    do {
        _ = try NetworkClient(configuration: configuration)
        Issue.record("Expected invalid configuration to fail initialization")
    } catch let error as NetworkClient.ConfigurationError {
        #expect(error.failures == expectedFailures)
    }
}
