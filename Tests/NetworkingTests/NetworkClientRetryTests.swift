//
//  NetworkClientRetryTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct NetworkClientRetryTests {
    @Test("Retry metadata advances per consumed HTTP response before final validation")
    func retryMetadataAndResponseAttemptHistoryAreChronological() async throws {
        let firstID = RequestID(rawValue: UUID())
        let contexts = Mutex<[RetryPolicy.Context]>([])
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 2
        configuration.customDecision = { context in
            contexts.withLock { $0.append(context) }
            return .useBuiltInDecision
        }
        let transport = ScriptedRetryTransport([
            .success(data: Data([0x01]), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x02]), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x03]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withRetryPolicy(RetryPolicy(configuration: configuration))
                .withRequestIDGenerator(FixedRetryRequestIDGenerator(requestID: firstID)),
        )
        let request = try makeRequest()
            .context(RetryTraceKey.self, value: "trace-1")

        let result = try await client.send(request)

        let recordedContexts = contexts.withLock { $0 }
        #expect(recordedContexts.count == 2)
        #expect(recordedContexts.map(\.attemptNumber) == [1, 2])
        #expect(recordedContexts.map(\.retryCount) == [0, 1])
        #expect(recordedContexts.allSatisfy { $0.builtInDecision == .retry })
        #expect(recordedContexts.allSatisfy { $0.method == .get })
        #expect(recordedContexts.allSatisfy { $0.requestID == firstID })
        #expect(recordedContexts.allSatisfy { $0.context[RetryTraceKey.self] == "trace-1" })
        #expect(recordedContexts.allSatisfy { $0.response?.status.code == 503 })
        #expect(result.value == Data([0x03]))
        #expect(result.requestID == firstID)
        #expect(result.attempts.map(\.attemptNumber) == [1, 2, 3])
        #expect(result.attempts.map(\.outcome) == [.retryScheduled, .retryScheduled, .acceptedResponse])
        #expect(result.attempts[0].diagnosticReason?.contains("503") == true)
        #expect(result.attempts[1].diagnosticReason?.contains("503") == true)
        #expect(await transport.executionCount == 3)
    }

    @Test("Configured method and status eligibility retries a custom HTTP response")
    func configuredMethodAndStatusCodesAreUsedForBuiltInDecisions() async throws {
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.retryableMethods = [.post]
        configuration.retryableStatusCodes = [418]
        let transport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 418), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        let result = try await client.send(makeRequest(method: .post))

        #expect(result.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
        #expect(result.value == Data([0x2a]))
        #expect(await transport.executionCount == 2)
    }

    @Test("Retry eligibility and context use the method produced by request adapters")
    func retryClassificationUsesAdaptedMethod() async throws {
        let methods = Mutex<[HTTPRequest.Method]>([])
        let policy = RetryPolicy { configuration in
            configuration.maximumRetries = 1
            configuration.customDecision = { context in
                methods.withLock { $0.append(context.method) }
                return .useBuiltInDecision
            }
        }
        let transport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withRetryPolicy(policy)
                .withRequestAdapter(AnyRequestAdapter(adapt: { context in
                    var request = context.request
                    request.method = .post
                    return request
                })),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected the adapted POST response to reach validation")
        } catch let error as ResponseValidationError {
            #expect(error.attempts.map(\.outcome) == [.validationRejection])
        }

        #expect(methods.withLock { $0 } == [.post])
        #expect(await transport.executionCount == 1)
    }

    @Test("Request retry policy replaces endpoint policy, which replaces client policy")
    func retryPolicyReplacementPrecedenceIsClientEndpointRequest() async throws {
        let clientPolicy = RetryPolicy { $0.maximumRetries = 1 }
        let endpoint = try Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(#require(URL(string: "https://example.com/retry"))),
            response: .data,
        )
        .retryPolicy { $0.maximumRetries = 0 }

        let endpointTransport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let endpointClient = try NetworkClient(
            transport: endpointTransport,
            configuration: .init().withRetryPolicy(clientPolicy),
        )
        do {
            _ = try await endpointClient.send(Request(endpoint: endpoint))
            Issue.record("Expected the endpoint policy to disable the client retry")
        } catch let error as ResponseValidationError {
            #expect(error.attempts.count == 1)
        }
        #expect(await endpointTransport.executionCount == 1)

        let requestTransport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let requestClient = try NetworkClient(
            transport: requestTransport,
            configuration: .init().withRetryPolicy(clientPolicy),
        )
        let request = Request(endpoint: endpoint)
            .retryPolicy { $0.maximumRetries = 2 }

        let result = try await requestClient.send(request)

        #expect(result.attempts.map(\.attemptNumber) == [1, 2, 3])
        #expect(await requestTransport.executionCount == 3)
    }

    @Test("Custom retry can override built-in rejection while the retry budget remains")
    func customDecisionCanForceRetryWithinBudget() async throws {
        let contexts = Mutex<[RetryPolicy.Context]>([])
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { context in
            contexts.withLock { $0.append(context) }
            return .retry
        }
        let transport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 418), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        let result = try await client.send(makeRequest(method: .post))

        #expect(contexts.withLock { $0.count } == 1)
        let builtInDecision = contexts.withLock { $0.first?.builtInDecision }
        #expect(builtInDecision == .some(.doNotRetry))
        #expect(result.attempts[0].outcome == .retryScheduled)
        #expect(result.attempts[0].diagnosticReason?.localizedCaseInsensitiveContains("custom") == true)
        #expect(await transport.executionCount == 2)
    }

    @Test("Custom do-not-retry decisions stop otherwise eligible responses and errors")
    func customDecisionCanVetoBuiltInRetries() async throws {
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { _ in .doNotRetry }

        let responseTransport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data(), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let responseClient = try NetworkClient(
            transport: responseTransport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )
        do {
            _ = try await responseClient.send(makeRequest())
            Issue.record("Expected the vetoed 503 response to reach validation")
        } catch let error as ResponseValidationError {
            #expect(error.attempts.map(\.outcome) == [.validationRejection])
        }
        #expect(await responseTransport.executionCount == 1)

        let errorTransport = ScriptedRetryTransport([
            .failure(error: URLError(.timedOut), rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data(), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let errorClient = try NetworkClient(
            transport: errorTransport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )
        do {
            _ = try await errorClient.send(makeRequest())
            Issue.record("Expected the vetoed transport error to propagate")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(await errorTransport.executionCount == 1)
    }

    @Test("Custom retry decisions cannot exceed the retry budget and are skipped when exhausted")
    func customDecisionIsSkippedAfterRetryBudgetIsUsed() async throws {
        let contexts = Mutex<[RetryPolicy.Context]>([])
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { context in
            contexts.withLock { $0.append(context) }
            return .retry
        }
        let transport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected the second 503 response to reach final validation")
        } catch let error as ResponseValidationError {
            #expect(error.attempts.map(\.attemptNumber) == [1, 2])
            #expect(error.attempts.map(\.outcome) == [.retryScheduled, .validationRejection])
        }

        #expect(contexts.withLock { $0.map(\.retryCount) } == [0])
        #expect(await transport.executionCount == 2)
    }

    @Test("Retryable transport failures remain transport failures in successful history")
    func transientTransportFailureCanRetryAndPreservesItsOutcome() async throws {
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        let transportError = URLError(.timedOut)
        let transport = ScriptedRetryTransport([
            .failure(error: transportError, rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        let result = try await client.send(makeRequest())

        #expect(result.attempts.map(\.attemptNumber) == [1, 2])
        #expect(result.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
        let diagnosticReason = try #require(result.attempts[0].diagnosticReason)
        #expect(diagnosticReason.contains(String(describing: transportError as NSError)))
        #expect(diagnosticReason.contains("built-in classification selected retry"))
        #expect(diagnosticReason.contains(String(describing: RetryPolicy.Reason.urlErrorCodeRetryable(.timedOut))))
        #expect(await transport.executionCount == 2)
    }

    @Test("Custom-forced transport retries retain the error and built-in classification reason")
    func customForcedTransportRetryRecordsDiagnosticSourceAndReason() async throws {
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { _ in .retry }
        let transportError = URLError(.resourceUnavailable)
        let transport = ScriptedRetryTransport([
            .failure(error: transportError, rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        let result = try await client.send(makeRequest())

        #expect(result.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
        let diagnosticReason = try #require(result.attempts[0].diagnosticReason)
        #expect(diagnosticReason.contains(String(describing: transportError as NSError)))
        #expect(diagnosticReason.contains("custom decision forced retry"))
        #expect(diagnosticReason
            .contains(String(describing: RetryPolicy.Reason.urlErrorCodeNotRetryable(.resourceUnavailable))))
        #expect(await transport.executionCount == 2)
    }

    @Test("A started CancellationError bypasses custom retry decisions")
    func startedCancellationErrorStopsBeforeCustomRetryDecision() async throws {
        let decisions = Mutex(0)
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { _ in
            decisions.withLock { $0 += 1 }
            return .retry
        }
        let transport = ScriptedRetryTransport([
            .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected transport cancellation to propagate")
        } catch is CancellationError {}

        #expect(decisions.withLock { $0 } == 0)
        #expect(await transport.executionCount == 1)
    }

    @Test("Final transport error is rethrown unchanged after a custom retry")
    func finalTransportErrorIdentityIsPreserved() async throws {
        let firstError = RetryMarkerError(identifier: "first")
        let finalError = RetryMarkerError(identifier: "final")
        let transportErrors = Mutex<[any Error]>([])
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { context in
            if let error = context.transportError {
                transportErrors.withLock { $0.append(error) }
            }
            return .retry
        }
        let transport = ScriptedRetryTransport([
            .failure(error: firstError, rawTaskMetrics: nil, didStartTask: true),
            .failure(error: finalError, rawTaskMetrics: nil, didStartTask: true),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected the final transport error to propagate")
        } catch {
            #expect(isSameError(error, as: finalError))
        }

        let recordedErrors = transportErrors.withLock { $0 }
        #expect(recordedErrors.count == 1)
        #expect(isSameError(recordedErrors[0], as: firstError))
        #expect(await transport.executionCount == 2)
    }

    @Test("Transport failures before task start bypass retry classification and preserve the error")
    func didNotStartIsPretransportAndDoesNotCallCustomDecision() async throws {
        let expectedError = RetryMarkerError(identifier: "pretransport")
        let decisions = Mutex(0)
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { _ in
            decisions.withLock { $0 += 1 }
            return .retry
        }
        let transport = ScriptedRetryTransport([
            .failure(error: expectedError, rawTaskMetrics: nil, didStartTask: false),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected the pretransport error to propagate")
        } catch {
            #expect(isSameError(error, as: expectedError))
        }

        #expect(decisions.withLock { $0 } == 0)
        #expect(await transport.executionCount == 1)
    }

    @Test("A configured URL error code can be added to built-in transport eligibility")
    func configuredURLErrorCodeRetriesTransportFailure() async throws {
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.retryableURLErrorCodes = [.resourceUnavailable]
        let transport = ScriptedRetryTransport([
            .failure(error: URLError(.resourceUnavailable), rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )

        let result = try await client.send(makeRequest())

        #expect(result.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
        #expect(await transport.executionCount == 2)
    }

    @Test("URLError cancellation is built-in nonretryable but a custom decision may override it")
    func cancelledURLErrorCanOnlyRetryThroughCustomDecision() async throws {
        var defaultConfiguration = RetryPolicy.Configuration()
        defaultConfiguration.maximumRetries = 1
        defaultConfiguration.retryableURLErrorCodes.insert(.cancelled)
        let builtInDecision = Mutex<RetryPolicy.Decision?>(nil)
        defaultConfiguration.customDecision = { context in
            builtInDecision.withLock { $0 = context.builtInDecision }
            return .useBuiltInDecision
        }
        let defaultTransport = ScriptedRetryTransport([
            .failure(error: URLError(.cancelled), rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data(), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let defaultClient = try NetworkClient(
            transport: defaultTransport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: defaultConfiguration)),
        )

        do {
            _ = try await defaultClient.send(makeRequest())
            Issue.record("Expected the built-in cancelled error to propagate")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(await defaultTransport.executionCount == 1)
        #expect(builtInDecision.withLock { $0 } == .doNotRetry)

        var overrideConfiguration = RetryPolicy.Configuration()
        overrideConfiguration.maximumRetries = 1
        overrideConfiguration.retryableURLErrorCodes.insert(.cancelled)
        overrideConfiguration.customDecision = { _ in .retry }
        let overrideTransport = ScriptedRetryTransport([
            .failure(error: URLError(.cancelled), rawTaskMetrics: nil, didStartTask: true),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let overrideClient = try NetworkClient(
            transport: overrideTransport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: overrideConfiguration)),
        )

        let result = try await overrideClient.send(makeRequest())

        #expect(result.attempts.map(\.outcome) == [.transportFailure, .acceptedResponse])
        #expect(await overrideTransport.executionCount == 2)
    }

    @Test("A cancelled Swift task stops before retry evaluation or another transport attempt")
    func taskCancellationStopsBeforeCustomRetryDecision() async throws {
        let decisions = Mutex(0)
        var configuration = RetryPolicy.Configuration()
        configuration.maximumRetries = 1
        configuration.customDecision = { _ in
            decisions.withLock { $0 += 1 }
            return .retry
        }
        let transport = GatedRetryFailureTransport(
            .failure(error: URLError(.timedOut), rawTaskMetrics: nil, didStartTask: true),
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: configuration)),
        )
        let task = try client.task(for: makeRequest())

        await transport.waitUntilEntered()
        task.cancel()
        await transport.release()
        do {
            _ = try await task.value
            Issue.record("Expected shared task cancellation to surface")
        } catch is CancellationError {}
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        #expect(decisions.withLock { $0 } == 0)
        #expect(await transport.executionCount == 1)
    }

    @Test("Each retry prepares the immutable body again and reruns adapters in order")
    func bodyPreparationAndAdaptersRepeatForEachAttempt() async throws {
        let bodyCalls = Mutex(0)
        let firstAdapterCalls = Mutex(0)
        let secondAdapterCalls = Mutex(0)
        let bodyEncoding = BodyEncoding<String>.custom { body in
            let attempt = bodyCalls.withLock { count -> Int in
                count += 1
                return count
            }
            return Data("\(body)-\(attempt)".utf8)
        }
        let endpoint = try Endpoint<Never, String, Data>.data(
            method: .post,
            route: .absolute(#require(URL(string: "https://example.com/retry"))),
            body: bodyEncoding,
            response: .data,
        )
        let firstAdapter = AnyRequestAdapter(adapt: { context in
            let attempt = firstAdapterCalls.withLock { count -> Int in
                count += 1
                return count
            }
            var request = context.request
            request.headerFields[fields: .accept] = [
                HTTPField(name: .accept, value: "adapter-\(attempt)"),
            ]
            return request
        })
        let secondAdapter = AnyRequestAdapter(adapt: { context in
            let previousValue = context.request.headerFields[fields: .accept].first?.value
            guard let previousValue else {
                throw RetryMarkerError(identifier: "adapter-order")
            }

            secondAdapterCalls.withLock { $0 += 1 }
            var request = context.request
            request.headerFields[fields: .contentType] = [
                HTTPField(name: .contentType, value: previousValue),
            ]
            return request
        })
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.retryableMethods = [.post]
        let transport = ScriptedRetryTransport([
            .success(data: Data(), response: response(status: 503), rawTaskMetrics: nil),
            .success(data: Data([0x2a]), response: response(status: 200), rawTaskMetrics: nil),
        ])
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
                .withRequestAdapter(firstAdapter)
                .withRequestAdapter(secondAdapter),
        )

        let result = try await client.send(Request(endpoint: endpoint, body: "payload"))

        let requests = await transport.recordedRequests()
        #expect(result.attempts.map(\.attemptNumber) == [1, 2])
        #expect(bodyCalls.withLock { $0 } == 2)
        #expect(firstAdapterCalls.withLock { $0 } == 2)
        #expect(secondAdapterCalls.withLock { $0 } == 2)
        #expect(requests.count == 2)
        #expect(requests[0].httpRequest.headerFields[fields: .accept].first?.value == "adapter-1")
        #expect(requests[1].httpRequest.headerFields[fields: .accept].first?.value == "adapter-2")
        #expect(requests[0].httpRequest.headerFields[fields: .contentType].first?.value == "adapter-1")
        #expect(requests[1].httpRequest.headerFields[fields: .contentType].first?.value == "adapter-2")
        guard case let .data(firstBody) = requests[0].body,
              case let .data(secondBody) = requests[1].body
        else {
            Issue.record("Expected each transport request to contain its prepared body")
            return
        }

        #expect(firstBody == Data("payload-1".utf8))
        #expect(secondBody == Data("payload-2".utf8))
    }
}

private enum RetryTraceKey: RequestContextKey {
    typealias Value = String
}

private final class RetryMarkerError: Error, Sendable {
    let identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }
}

private func isSameError(_ error: any Error, as expected: RetryMarkerError) -> Bool {
    (error as AnyObject) === expected
}

private struct FixedRetryRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private actor ScriptedRetryTransport: NetworkTransport {
    private var results: [NetworkTransportResult]
    private var requests: [TransportRequest] = []

    init(_ results: [NetworkTransportResult]) {
        self.results = results
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw RetryMarkerError(identifier: "unexpected legacy transport call")
    }

    func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        requests.append(request)
        guard !results.isEmpty else {
            return .failure(
                error: RetryMarkerError(identifier: "script exhausted"),
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

private actor GatedRetryFailureTransport: NetworkTransport {
    private let result: NetworkTransportResult
    private var requests: [TransportRequest] = []
    private var entered = false
    private var resultContinuation: CheckedContinuation<NetworkTransportResult, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ result: NetworkTransportResult) {
        self.result = result
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw RetryMarkerError(identifier: "unexpected legacy transport call")
    }

    func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        guard let resultContinuation else {
            return
        }

        self.resultContinuation = nil
        resultContinuation.resume(returning: result)
    }

    var executionCount: Int {
        requests.count
    }
}

private func makeRequest(method: HTTPRequest.Method = .get) throws -> Request<Data> {
    let url = try #require(URL(string: "https://example.com/retry"))
    let endpoint = Endpoint<Never, Never, Data>.data(
        method: method,
        route: .absolute(url),
        response: .data,
    )
    return Request(endpoint: endpoint)
}

private func response(status: Int) -> HTTPResponse {
    HTTPResponse(status: .init(code: status))
}
