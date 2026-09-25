//
//  AuthenticationTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct AuthenticationTests {
    @Test("Endpoint authentication requirements survive every endpoint copy modifier")
    func endpointCopyModifiersPreserveAuthenticationRequirement() throws {
        let url = try #require(URL(string: "https://example.com/authentication"))
        let requirement = AuthenticationRequirement.required(maximumReplays: 2)
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        .authenticationRequirement(requirement)
        #expect(Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        .authenticationRequirement == .none)
        #expect(AuthenticationRequirement.required() == .required(maximumReplays: 1))
        let inputEndpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "witness") { _ in url },
            response: .data,
        )
        .authenticationRequirement(requirement)

        let fixedHeaderCopies = [
            endpoint.headers(HTTPFields()),
            endpoint.header(.accept, "application/json"),
            endpoint.jsonEncoderConfiguration { _ in },
            endpoint.jsonDecoderConfiguration { _ in },
            endpoint.validationPolicy(.successfulStatusCodes),
            endpoint.successfulResponseBodyRetentionPolicy(.none),
            endpoint.validationErrorBodyRetentionPolicy(.unlimited),
            endpoint.retryPolicy(RetryPolicy()),
            endpoint.retryPolicy { $0.maximumRetries = 2 },
        ]
        let inputHeaderCopies = [
            inputEndpoint.headers { _ in HTTPFields() },
            inputEndpoint.header(.accept, "application/json"),
        ]

        #expect(fixedHeaderCopies.map(\.authenticationRequirement) == Array(
            repeating: requirement,
            count: fixedHeaderCopies.count,
        ))
        #expect(inputHeaderCopies.map(\.authenticationRequirement) == Array(
            repeating: requirement,
            count: inputHeaderCopies.count,
        ))
        #expect(endpoint.authenticationRequirement(.required(maximumReplays: 3))
            .authenticationRequirement == .required(maximumReplays: 3))
    }

    @Test("Request binding and every request copy modifier retain the endpoint requirement")
    func requestBindingAndCopyModifiersPreserveAuthenticationRequirement() throws {
        let url = try #require(URL(string: "https://example.com/authentication"))
        let requirement = AuthenticationRequirement.required(maximumReplays: 2)
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        .authenticationRequirement(requirement)
        let inputEndpoint = Endpoint<String, Never, Data>.data(
            method: .get,
            route: .absolute(forInput: "witness") { _ in url },
            response: .data,
        )
        .authenticationRequirement(requirement)
        let bodyfulEndpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(url),
            body: .data(),
            response: .data,
        )
        .authenticationRequirement(requirement)
        let inputBodyfulEndpoint = Endpoint<String, Data, Data>.data(
            method: .post,
            route: .absolute(forInput: "witness") { _ in url },
            body: .data(),
            response: .data,
        )
        .authenticationRequirement(requirement)

        let boundRequests = [
            Request(endpoint: endpoint),
            Request(endpoint: inputEndpoint, input: "item"),
            Request(endpoint: bodyfulEndpoint, body: Data([1])),
            Request(endpoint: inputBodyfulEndpoint, input: "item", body: Data([1])),
        ]
        #expect(boundRequests.map(\.authenticationRequirement) == Array(repeating: requirement, count: 4))

        let request = boundRequests[0]
        let copies = [
            request.context(AuthenticationTraceKey.self, value: "trace"),
            request.queryItems([URLQueryItem(name: "page", value: "1")]),
            request.headers(HTTPFields()),
            request.header(.accept, "application/json"),
            request.validationPolicy(.successfulStatusCodes),
            request.successfulResponseBodyRetentionPolicy(.none),
            request.validationErrorBodyRetentionPolicy(.unlimited),
            request.retryPolicy(RetryPolicy()),
            request.retryPolicy { $0.maximumRetries = 2 },
        ]

        #expect(copies.map(\.authenticationRequirement) == Array(repeating: requirement, count: copies.count))
    }

    @Test("Authentication provider replacement and every configuration copy preserve provider state")
    func configurationCopyModifiersPreserveAuthenticationProvider() {
        let provider = PassthroughAuthenticationProvider()
        let configuration = NetworkClient.Configuration().withAuthenticationProvider(provider)

        #expect(NetworkClient.Configuration().authenticationProvider == nil)

        let copies = [
            configuration.withDefaultQueryItems([URLQueryItem(name: "page", value: "1")]),
            configuration.withURLQueryEncoderConfiguration(.init()),
            configuration.withJSONEncoderConfiguration { _ in },
            configuration.withJSONDecoderConfiguration { _ in },
            configuration.withRequestIDGenerator(UUIDRequestIDGenerator()),
            configuration.withRequestAdapter(AnyRequestAdapter(adapt: { $0.request })),
            configuration.withDefaultHeaders(HTTPFields()),
            configuration.withURLCache(nil),
            configuration.withHTTPCookieStorage(nil),
            configuration.withRequestTimeout(.seconds(10)),
            configuration.withResourceTimeout(.seconds(20)),
            configuration.withWaitsForConnectivity(true),
            configuration.withAllowsExpensiveNetworkAccess(true),
            configuration.withAllowsConstrainedNetworkAccess(true),
            configuration.withAllowsCellularAccess(true),
            configuration.withCachePolicy(.reloadIgnoringLocalCacheData),
            configuration.withResponseValidationPolicy(.successfulStatusCodes),
            configuration.withRetryPolicy(RetryPolicy()),
            configuration.withSuccessfulResponseBodyRetentionPolicy(.none),
            configuration.withValidationErrorBodyRetentionPolicy(.unlimited),
            configuration.withAssumesHTTP3Capable(true),
        ]

        #expect(copies.allSatisfy { $0.authenticationProvider is PassthroughAuthenticationProvider })
        #expect(configuration.withAuthenticationProvider(nil).authenticationProvider == nil)
        let replacementProvider = PassthroughAuthenticationProvider()
        #expect(configuration.withAuthenticationProvider(replacementProvider)
            .authenticationProvider is PassthroughAuthenticationProvider)
    }

    @Test("A configured authentication provider stays dormant for endpoints without a requirement")
    func providerIsDormantForUnauthenticatedEndpoints() async throws {
        let provider = AuthenticationTestProvider()
        let transport = AuthenticationScriptedTransport([.success(
            data: Data([0x2a]),
            response: response(status: 200),
            rawTaskMetrics: nil,
        )])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(provider),
        )

        _ = try await client.send(makeRequest())

        #expect(await provider.adaptationCallCount == 0)
        #expect(await provider.recoveryCallCount == 0)
        #expect(await transport.executionCount == 1)
    }

    @Test("A required request without a provider fails before body preparation, adapters, or transport")
    func missingProviderFailsBeforeAttemptPreparation() async throws {
        let requestID = try RequestID(rawValue: #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")))
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let transport = AuthenticationScriptedTransport([])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .post,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            body: .custom(encode: { body in
                bodyPreparationCount.withLock { $0 += 1 }
                return Data([UInt8(body)])
            }),
            response: .data,
        )
        .authenticationRequirement(.required())
        let configuration = NetworkClient.Configuration()
            .withRequestIDGenerator(AuthenticationFixedRequestIDGenerator(requestID: requestID))
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                return context.request
            }))
        let client = try NetworkClient(transport: transport, configuration: configuration)

        do {
            _ = try await client.send(Request(endpoint: endpoint, body: 7))
            Issue.record("Expected the missing authentication provider to fail")
        } catch let error as AuthenticationConfigurationError {
            #expect(error.requestID == requestID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(bodyPreparationCount.withLock { $0 } == 0)
        #expect(adapterCallCount.withLock { $0 } == 0)
        #expect(await transport.executionCount == 0)
    }

    @Test("Query preflight errors retain precedence over missing authentication configuration")
    func queryPreflightFailurePrecedesMissingProviderError() async throws {
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let transport = AuthenticationScriptedTransport([])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .post,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            body: .custom(encode: { body in
                bodyPreparationCount.withLock { $0 += 1 }
                return Data([UInt8(body)])
            }),
            response: .data,
            query: .codable(Set([1, 2])),
        )
        .authenticationRequirement(.required())
        let configuration = NetworkClient.Configuration()
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                return context.request
            }))
        let client = try NetworkClient(transport: transport, configuration: configuration)

        do {
            _ = try await client.send(Request(endpoint: endpoint, body: 7))
            Issue.record("Expected the unordered query to fail during preflight")
        } catch {
            #expect(error is RequestConstructionError)
        }

        #expect(bodyPreparationCount.withLock { $0 } == 0)
        #expect(adapterCallCount.withLock { $0 } == 0)
        #expect(await transport.executionCount == 0)
    }

    @Test("Route preflight errors retain precedence over missing authentication configuration")
    func routePreflightFailurePrecedesMissingProviderError() async throws {
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let transport = AuthenticationScriptedTransport([])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .post,
            route: .absolute(#require(URL(string: "file:///tmp/authentication"))),
            body: .custom(encode: { body in
                bodyPreparationCount.withLock { $0 += 1 }
                return Data([UInt8(body)])
            }),
            response: .data,
        )
        .authenticationRequirement(.required())
        let configuration = NetworkClient.Configuration()
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                return context.request
            }))
        let client = try NetworkClient(transport: transport, configuration: configuration)

        do {
            _ = try await client.send(Request(endpoint: endpoint, body: 7))
            Issue.record("Expected the unsupported route scheme to fail during preflight")
        } catch {
            #expect(error is RequestConstructionError)
        }

        #expect(bodyPreparationCount.withLock { $0 } == 0)
        #expect(adapterCallCount.withLock { $0 } == 0)
        #expect(await transport.executionCount == 0)
    }

    @Test("Authentication adaptation runs last and ordinary retry classifies its returned method")
    func finalAuthenticatedMethodControlsOrdinaryRetry() async throws {
        let events = AuthenticationEventLog()
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let sleeps = Mutex<[Duration]>([])
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.retryableMethods = [.post]
        retryConfiguration.retryableStatusCodes = [503]
        let policy = RetryPolicy(configuration: retryConfiguration)
        let provider = AuthenticationTestProvider(
            adaptation: { incomingRequest in
                var authenticatedRequest = incomingRequest
                authenticatedRequest.method = .post
                return authenticatedRequest
            },
            events: events,
        )
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0x01]), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x02]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            body: .custom(encode: { body in
                bodyPreparationCount.withLock { $0 += 1 }
                events.append("body")
                return Data([UInt8(body)])
            }),
            response: .data,
        )
        .authenticationRequirement(.required(maximumReplays: 0))
        let configuration = NetworkClient.Configuration()
            .withAuthenticationProvider(provider)
            .withRetryPolicy(policy)
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                events.append("adapter-1")
                var request = context.request
                request.method = .patch
                return request
            }))
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                events.append("adapter-2")
                return context.request
            }))
        let timing = RetryTimingDependencies(
            sleep: { duration in sleeps.withLock { $0.append(duration) } },
            now: { Date(timeIntervalSince1970: 0) },
            randomUnit: { 0.5 },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: configuration,
            retryTimingDependencies: timing,
        )

        let result = try await client.send(Request(endpoint: endpoint, body: 9))
        let sentRequests = await transport.recordedRequests()
        let adaptationContexts = await provider.recordedAdaptationContexts()

        #expect(sentRequests.map(\.httpRequest.method) == [.post, .post])
        #expect(adaptationContexts.map(\.request.method) == [.patch, .patch])
        #expect(result.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
        #expect(await provider.adaptationCallCount == 2)
        #expect(await provider.recoveryCallCount == 0)
        #expect(bodyPreparationCount.withLock { $0 } == 2)
        #expect(adapterCallCount.withLock { $0 } == 4)
        #expect(sleeps.withLock { $0 } == [])
        #expect(events.values == [
            "body",
            "adapter-1",
            "adapter-2",
            "authentication",
            "body",
            "adapter-1",
            "adapter-2",
            "authentication",
        ])
    }

    @Test("Authentication replay reconstructs the attempt and records its full recovery context")
    func replayRebuildsAttemptAndRecordsRecoveryContext() async throws {
        let requestID = try RequestID(rawValue: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")))
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let sleeps = Mutex<[Duration]>([])
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.backoffStrategy = .constant(.seconds(5), jitter: .none)
        retryConfiguration.retryableMethods = [.post]
        retryConfiguration.retryableStatusCodes = [401]
        let provider = AuthenticationTestProvider(
            adaptation: { incomingRequest in
                var authenticatedRequest = incomingRequest
                authenticatedRequest.method = .post
                return authenticatedRequest
            },
            recoveries: [.replay],
        )
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0xa1]), response: response(status: 401), rawTaskMetrics: nil),
            .success(data: Data([0xb2]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            body: .custom(encode: { body in
                let attempt = bodyPreparationCount.withLock { count in
                    count += 1
                    return count
                }
                return Data([UInt8(body), UInt8(attempt)])
            }),
            response: .data,
        )
        .authenticationRequirement(.required())
        let request = Request(endpoint: endpoint, body: 7)
            .context(AuthenticationTraceKey.self, value: "trace-123")
        let configuration = NetworkClient.Configuration()
            .withAuthenticationProvider(provider)
            .withRequestIDGenerator(AuthenticationFixedRequestIDGenerator(requestID: requestID))
            .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                return context.request
            }))
        let timing = RetryTimingDependencies(
            sleep: { duration in sleeps.withLock { $0.append(duration) } },
            now: { Date(timeIntervalSince1970: 0) },
            randomUnit: { 0.5 },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: configuration,
            retryTimingDependencies: timing,
        )

        let result = try await client.send(request)
        let sentRequests = await transport.recordedRequests()
        let recoveryContexts = await provider.recordedRecoveryContexts()
        let adaptationContexts = await provider.recordedAdaptationContexts()

        #expect(result.requestID == requestID)
        #expect(result.attempts.map(\.attemptNumber) == [1, 2])
        #expect(result.attempts.map(\.outcome) == [.authenticationReplayScheduled, .acceptedResponse])
        #expect(sentRequests.map(\.httpRequest.method) == [.post, .post])
        #expect(sentRequests.map(bodyData) == [Data([7, 1]), Data([7, 2])])
        #expect(await provider.adaptationCallCount == 2)
        #expect(await provider.recoveryCallCount == 1)
        #expect(bodyPreparationCount.withLock { $0 } == 2)
        #expect(adapterCallCount.withLock { $0 } == 2)
        #expect(sleeps.withLock { $0 } == [])
        #expect(adaptationContexts.map(\.request.method) == [.get, .get])
        #expect(adaptationContexts.map(\.requestID) == [requestID, requestID])
        #expect(adaptationContexts.map { $0.context[AuthenticationTraceKey.self] } == ["trace-123", "trace-123"])
        #expect(adaptationContexts.map { bodyData($0.body) } == [Data([7, 1]), Data([7, 2])])

        let recoveryContext = try #require(recoveryContexts.first)
        #expect(recoveryContext.request.method == .post)
        #expect(recoveryContext.httpResponse.status.code == 401)
        #expect(recoveryContext.requestContext[AuthenticationTraceKey.self] == "trace-123")
        #expect(recoveryContext.requestID == requestID)
        #expect(recoveryContext.attemptNumber == 1)
        if case let .data(receivedBody) = recoveryContext.receivedBody {
            #expect(receivedBody == Data([0xa1]))
        } else {
            Issue.record("Expected the received response body to contain the transport data")
        }
    }

    @Test("Authentication replay and ordinary retry use separate budgets and one chronological attempt sequence")
    func authenticationReplayAndOrdinaryRetryBudgetsAreIndependent() async throws {
        let bodyPreparationCount = Mutex(0)
        let adapterCallCount = Mutex(0)
        let sleeps = Mutex<[Duration]>([])
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.backoffStrategy = .constant(.seconds(7), jitter: .none)
        retryConfiguration.retryableMethods = [.post]
        retryConfiguration.retryableStatusCodes = [503]
        let provider = AuthenticationTestProvider(
            adaptation: { incomingRequest in
                var authenticatedRequest = incomingRequest
                authenticatedRequest.method = .post
                return authenticatedRequest
            },
            recoveries: [.replay],
        )
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0x01]), response: response(status: 401), rawTaskMetrics: nil),
            .success(data: Data([0x02]), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x03]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Int, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            body: .custom(encode: { body in
                let attempt = bodyPreparationCount.withLock { count in
                    count += 1
                    return count
                }
                return Data([UInt8(body), UInt8(attempt)])
            }),
            response: .data,
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        let configuration = NetworkClient.Configuration()
            .withAuthenticationProvider(provider)
            .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
            .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                adapterCallCount.withLock { $0 += 1 }
                return context.request
            }))
        let timing = RetryTimingDependencies(
            sleep: { duration in sleeps.withLock { $0.append(duration) } },
            now: { Date(timeIntervalSince1970: 0) },
            randomUnit: { 0.5 },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: configuration,
            retryTimingDependencies: timing,
        )

        let result = try await client.send(Request(endpoint: endpoint, body: 4))
        let sentRequests = await transport.recordedRequests()

        #expect(result.attempts.map(\.attemptNumber) == [1, 2, 3])
        #expect(result.attempts.map(\.outcome) == [.authenticationReplayScheduled, .retryScheduled, .acceptedResponse])
        #expect(sentRequests.map(bodyData) == [Data([4, 1]), Data([4, 2]), Data([4, 3])])
        #expect(await provider.adaptationCallCount == 3)
        #expect(await provider.recoveryCallCount == 1)
        #expect(bodyPreparationCount.withLock { $0 } == 3)
        #expect(adapterCallCount.withLock { $0 } == 3)
        #expect(sleeps.withLock { $0 } == [.seconds(7)])
    }

    @Test("A recovery decision not to replay leaves the same response in ordinary retry selection")
    func doNotReplayContinuesThroughOrdinaryRetry() async throws {
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.retryableMethods = [.post]
        retryConfiguration.retryableStatusCodes = [503]
        let provider = AuthenticationTestProvider(
            adaptation: { incomingRequest in
                var authenticatedRequest = incomingRequest
                authenticatedRequest.method = .post
                return authenticatedRequest
            },
            recoveries: [.doNotReplay],
        )
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0x01]), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x02]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withAuthenticationProvider(provider)
                .withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        )

        let result = try await client.send(Request(endpoint: endpoint))

        #expect(result.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
        #expect(await provider.recoveryCallCount == 2)
        #expect(await transport.executionCount == 2)
    }

    @Test("Authentication adaptation may return the incoming request unchanged")
    func authenticationAdaptationCanReturnUnchangedRequest() async throws {
        let provider = AuthenticationTestProvider()
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(provider),
        )

        let result = try await client.send(Request(endpoint: endpoint))
        let sentRequests = await transport.recordedRequests()

        #expect(result.attempts.map(\.outcome) == [.acceptedResponse])
        #expect(sentRequests.first?.httpRequest.method == .get)
        #expect(await provider.adaptationCallCount == 1)
        #expect(await provider.recoveryCallCount == 1)
    }

    @Test("Provider adaptation and recovery errors propagate unchanged without retry or validation")
    func providerErrorsPropagateWithoutRetryOrValidation() async throws {
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 2
        retryConfiguration.retryableMethods = [.get]
        retryConfiguration.retryableStatusCodes = [503]
        let adaptationFailure = AuthenticationTestError.adaptation
        let adaptationProvider = AuthenticationTestProvider(adaptationError: adaptationFailure)
        let adaptationTransport = AuthenticationScriptedTransport([])
        let adaptationEndpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let adaptationClient = try NetworkClient(
            transport: adaptationTransport,
            configuration: .init().withAuthenticationProvider(adaptationProvider),
        )

        do {
            _ = try await adaptationClient.send(Request(endpoint: adaptationEndpoint))
            Issue.record("Expected provider adaptation to throw")
        } catch {
            #expect(error as? AuthenticationTestError == adaptationFailure)
        }

        #expect(await adaptationTransport.executionCount == 0)
        #expect(await adaptationProvider.recoveryCallCount == 0)

        let validationCallCount = Mutex(0)
        let recoveryFailure = AuthenticationTestError.recovery
        let recoveryProvider = AuthenticationTestProvider(recoveryError: recoveryFailure)
        let recoveryTransport = AuthenticationScriptedTransport([
            .success(data: Data([0x01]), response: response(status: 503), rawTaskMetrics: nil),
        ])
        let recoveryEndpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        .validationPolicy(.custom(validate: { _ in
            validationCallCount.withLock { $0 += 1 }
            return .accept
        }))
        let recoveryClient = try NetworkClient(
            transport: recoveryTransport,
            configuration: .init()
                .withAuthenticationProvider(recoveryProvider)
                .withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        )

        do {
            _ = try await recoveryClient.send(Request(endpoint: recoveryEndpoint))
            Issue.record("Expected provider recovery to throw")
        } catch {
            #expect(error as? AuthenticationTestError == recoveryFailure)
        }

        #expect(await recoveryTransport.executionCount == 1)
        #expect(await recoveryProvider.recoveryCallCount == 1)
        #expect(validationCallCount.withLock { $0 } == 0)
    }

    @Test("Provider recovery is skipped for transport failures")
    func transportFailuresDoNotInvokeRecovery() async throws {
        let provider = AuthenticationTestProvider()
        let transport = AuthenticationScriptedTransport([
            .failure(error: URLError(.timedOut), rawTaskMetrics: nil, didStartTask: true),
        ])
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(provider),
        )

        do {
            _ = try await client.send(Request(endpoint: endpoint))
            Issue.record("Expected the scripted transport failure")
        } catch is URLError {}

        #expect(await provider.adaptationCallCount == 1)
        #expect(await provider.recoveryCallCount == 0)
    }

    @Test("Cancellation during provider adaptation prevents transport execution")
    func cancellationDuringAdaptationPreventsTransport() async throws {
        let provider = AuthenticationTestProvider(suspendsDuringAdaptation: true)
        let transport = AuthenticationScriptedTransport([])
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(provider),
        )
        let task = client.task(for: Request(endpoint: endpoint))

        await provider.waitUntilAdaptationStarts()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation during provider adaptation")
        } catch is CancellationError {}

        #expect(await transport.executionCount == 0)
    }

    @Test("Cancellation during provider recovery prevents a replay attempt")
    func cancellationDuringRecoveryPreventsReplay() async throws {
        let provider = AuthenticationTestProvider(suspendsDuringRecovery: true)
        let transport = AuthenticationScriptedTransport([
            .success(data: Data([0x01]), response: response(status: 401), rawTaskMetrics: nil),
        ])
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/authentication"))),
            response: .data,
        )
        .authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(provider),
        )
        let task = client.task(for: Request(endpoint: endpoint))

        await provider.waitUntilRecoveryStarts()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation during provider recovery")
        } catch is CancellationError {}

        #expect(await transport.executionCount == 1)
    }
}

private struct AuthenticationTraceKey: RequestContextKey {
    typealias Value = String
}

private struct PassthroughAuthenticationProvider: AuthenticationProvider {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        context.request
    }

    func recover(_: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        .doNotReplay
    }
}

private enum AuthenticationTestError: Error, Sendable, Equatable {
    case adaptation
    case recovery
    case unexpectedTransportCall
}

private actor AuthenticationScriptedTransport: NetworkTransport {
    private var results: [NetworkTransportResult]
    private var requests: [TransportRequest] = []

    init(_ results: [NetworkTransportResult]) {
        self.results = results
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw AuthenticationTestError.unexpectedTransportCall
    }

    func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        requests.append(request)
        guard !results.isEmpty else {
            return .failure(
                error: AuthenticationTestError.unexpectedTransportCall,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        return results.removeFirst()
    }

    var executionCount: Int {
        requests.count
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }
}

private actor AuthenticationTestProvider: AuthenticationProvider {
    private let adaptation: @Sendable (HTTPRequest) -> HTTPRequest
    private let adaptationError: AuthenticationTestError?
    private let recoveryError: AuthenticationTestError?
    private let suspendsDuringAdaptation: Bool
    private let suspendsDuringRecovery: Bool
    private let events: AuthenticationEventLog?
    private var remainingRecoveries: [AuthenticationRecovery]
    private var adaptationContexts: [RequestAdaptationContext] = []
    private var recoveryContexts: [AuthenticationRecoveryContext] = []
    private var adaptationWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        adaptation: @escaping @Sendable (HTTPRequest) -> HTTPRequest = { $0 },
        recoveries: [AuthenticationRecovery] = [],
        adaptationError: AuthenticationTestError? = nil,
        recoveryError: AuthenticationTestError? = nil,
        suspendsDuringAdaptation: Bool = false,
        suspendsDuringRecovery: Bool = false,
        events: AuthenticationEventLog? = nil,
    ) {
        self.adaptation = adaptation
        remainingRecoveries = recoveries
        self.adaptationError = adaptationError
        self.recoveryError = recoveryError
        self.suspendsDuringAdaptation = suspendsDuringAdaptation
        self.suspendsDuringRecovery = suspendsDuringRecovery
        self.events = events
    }

    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        adaptationContexts.append(context)
        events?.append("authentication")
        resume(&adaptationWaiters)
        if suspendsDuringAdaptation {
            try await Task.sleep(for: .seconds(3_600))
        }
        if let adaptationError {
            throw adaptationError
        }
        return adaptation(context.request)
    }

    func recover(_ context: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        recoveryContexts.append(context)
        events?.append("recovery")
        resume(&recoveryWaiters)
        if suspendsDuringRecovery {
            try await Task.sleep(for: .seconds(3_600))
        }
        if let recoveryError {
            throw recoveryError
        }
        guard !remainingRecoveries.isEmpty else {
            return .doNotReplay
        }

        return remainingRecoveries.removeFirst()
    }

    var adaptationCallCount: Int {
        adaptationContexts.count
    }

    var recoveryCallCount: Int {
        recoveryContexts.count
    }

    func recordedAdaptationContexts() -> [RequestAdaptationContext] {
        adaptationContexts
    }

    func recordedRecoveryContexts() -> [AuthenticationRecoveryContext] {
        recoveryContexts
    }

    func waitUntilAdaptationStarts() async {
        guard adaptationContexts.isEmpty else {
            return
        }

        await withCheckedContinuation { adaptationWaiters.append($0) }
    }

    func waitUntilRecoveryStarts() async {
        guard recoveryContexts.isEmpty else {
            return
        }

        await withCheckedContinuation { recoveryWaiters.append($0) }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private struct AuthenticationFixedRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private final class AuthenticationEventLog: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] {
        storage.withLock { $0 }
    }

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }
}

private func makeRequest() throws -> Request<Data> {
    let endpoint = try Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(#require(URL(string: "https://example.com/authentication"))),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func response(status: Int) -> HTTPResponse {
    HTTPResponse(status: .init(code: status))
}

private func bodyData(_ request: TransportRequest) -> Data? {
    guard case let .data(data) = request.body else {
        return nil
    }

    return data
}

private func bodyData(_ body: PreparedRequestBody) -> Data? {
    guard case let .data(data) = body else {
        return nil
    }

    return data
}
