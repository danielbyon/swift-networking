//
//  MockNetworkTransport.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Networking

/// Controls how many matching transport attempts consume a stub.
public enum StubConsumption: Sendable, Equatable {
    /// Consumes the stub on the first matching attempt.
    case once

    /// Consumes the stub for the given positive number of matching attempts.
    case finite(Int)

    /// Keeps the stub active for every matching attempt.
    case always
}

/// A value describing which transport-ready requests match and how the mock responds.
public struct NetworkStub: Sendable {
    /// Errors raised while constructing an invalid stub.
    public enum ConfigurationError: Error, Sendable, Equatable {
        /// Finite stub consumption must be greater than zero.
        case finiteConsumptionMustBePositive
    }

    /// The request predicate used to select this stub.
    public let matcher: RequestMatcher

    /// The response or failure produced by a matching attempt.
    public let response: StubResponse

    /// The number of matching attempts that may consume this stub.
    public let consumption: StubConsumption

    /// The deterministic pause points the attempt reaches before its scripted observable actions.
    public let latency: StubLatency?

    /// The byte-transfer updates the attempt publishes through the normal progress seam.
    public let progress: [StubProgressUpdate]

    /// The library-owned normalized metrics delivered with the stub's terminal result.
    public let metrics: NormalizedAttemptMetrics?

    /// Creates a stub with immutable matching, response, and consumption configuration.
    ///
    /// - Throws: `ConfigurationError.finiteConsumptionMustBePositive` when the count is zero or less.
    /// - Parameters:
    ///   - matcher: The request predicate used to select this stub.
    ///   - response: The response or failure produced by a matching attempt.
    ///   - consumption: The number of matching attempts that may consume this stub.
    ///   - latency: The pause points the attempt reaches before each scripted update and before
    ///     the terminal response. Defaults to no pauses.
    ///   - progress: The byte-transfer updates published before the terminal response. Defaults to
    ///     no scripted updates.
    ///   - metrics: Normalized attempt diagnostics reported with the terminal result. Defaults to
    ///     no supplied metrics, so attempt histories derive their normalized values from raw task
    ///     metrics, which mock attempts leave empty.
    public init(
        matching matcher: RequestMatcher,
        response: StubResponse,
        consumption: StubConsumption = .once,
        latency: StubLatency? = nil,
        progress: [StubProgressUpdate] = [],
        metrics: NormalizedAttemptMetrics? = nil,
    ) throws {
        if case let .finite(count) = consumption, count <= 0 {
            throw ConfigurationError.finiteConsumptionMustBePositive
        }
        self.matcher = matcher
        self.response = response
        self.consumption = consumption
        self.latency = latency
        self.progress = progress
        self.metrics = metrics
    }
}

/// A deterministic response produced by `MockNetworkTransport`.
public enum StubResponse: Sendable {
    /// Returns in-memory response bytes and an HTTP response.
    case httpResponse(data: Data, response: HTTPResponse)

    /// Throws the supplied error from the transport attempt.
    case failure(any Error)

    /// Returns response bytes through the library-owned download-file lifecycle.
    case download(data: Data, response: HTTPResponse)

    /// Follows scripted redirect proposals inside this attempt before delivering the terminal response.
    ///
    /// Each proposal is evaluated by the configured `RedirectPolicy`, produces a
    /// `redirectDecision` lifecycle event, and counts against the policy's per-attempt redirect
    /// limit. Redirects never consume another stub, never start another attempt, and never re-enter
    /// general adapters or authentication. A rejected proposal ends the attempt with that redirect
    /// response, and exhausting the limit fails the attempt with `RedirectError`.
    indirect case redirect(proposals: [StubRedirect], followedBy: StubResponse)
}

/// One redirect proposal evaluated inside a single mock transport attempt.
public struct StubRedirect: Sendable {
    /// The HTTP response that proposes the redirect.
    public let response: HTTPResponse

    /// The body delivered with the response when the configured policy rejects the proposal.
    public let body: Data

    /// The Foundation request the transport proposes to use when the policy follows the redirect.
    ///
    /// Tests supply the request directly so custom redirect policies observe the same request
    /// fidelity they receive from URLSession, including method, headers, and body state.
    public let proposedRequest: URLRequest

    /// Creates one redirect proposal for a mock transport attempt.
    ///
    /// - Parameters:
    ///   - response: The HTTP response that proposes the redirect.
    ///   - proposedRequest: The Foundation request proposed for the redirect destination.
    ///   - body: The body delivered when the policy rejects the proposal. Defaults to empty data.
    public init(response: HTTPResponse, proposedRequest: URLRequest, body: Data = Data()) {
        self.response = response
        self.body = body
        self.proposedRequest = proposedRequest
    }
}

/// One scripted byte-transfer update published during a mock transport attempt.
public enum StubProgressUpdate: Sendable, Equatable {
    /// Reports request-body bytes sent during the attempt.
    case upload(bytesSent: Int64, expectedBytesToSend: Int64?)

    /// Reports response-body bytes received during the attempt.
    case download(bytesReceived: Int64, expectedBytesToReceive: Int64?)
}

/// A snapshot of one actual transport attempt received by the mock.
public struct RecordedRequest: Sendable {
    /// The final HTTP request after general adapters and authentication adaptation.
    public let httpRequest: HTTPRequest

    /// The prepared request body, retaining file-backed bodies as URLs without reading their bytes.
    public let preparedBody: PreparedRequestBody

    /// The file size captured as metadata for a file-backed prepared body, when available.
    public let preparedBodyFileSize: UInt64?

    /// The identity shared by all attempts in one logical request execution.
    public let requestID: RequestID

    /// The one-based transport attempt number.
    public let attemptNumber: UInt

    /// Typed metadata associated with the logical request.
    public let requestContext: RequestContext

    /// Whether cancellation reached the mock after this transport attempt started.
    public let cancellationObserved: Bool

    package init(
        httpRequest: HTTPRequest,
        preparedBody: PreparedRequestBody,
        requestID: RequestID,
        attemptNumber: UInt,
        requestContext: RequestContext,
        cancellationObserved: Bool = false,
    ) {
        self.httpRequest = httpRequest
        self.preparedBody = preparedBody
        if case let .file(url) = preparedBody,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? NSNumber {
            preparedBodyFileSize = fileSize.uint64Value
        } else {
            preparedBodyFileSize = nil
        }
        self.requestID = requestID
        self.attemptNumber = attemptNumber
        self.requestContext = requestContext
        self.cancellationObserved = cancellationObserved
    }

    private init(copying request: Self, cancellationObserved: Bool) {
        httpRequest = request.httpRequest
        preparedBody = request.preparedBody
        preparedBodyFileSize = request.preparedBodyFileSize
        requestID = request.requestID
        attemptNumber = request.attemptNumber
        requestContext = request.requestContext
        self.cancellationObserved = cancellationObserved
    }

    /// Reads prepared body bytes explicitly; bodyless requests return empty data.
    ///
    /// File-backed bodies are read only when this method is called or a byte matcher is evaluated.
    public func readBodyBytes() throws -> Data {
        switch preparedBody {
        case .none:
            Data()
        case let .data(data):
            data
        case let .file(url):
            try Data(contentsOf: url)
        }
    }

    package func observingCancellation() -> Self {
        Self(copying: self, cancellationObserved: true)
    }
}

/// Recorded attempts from one logical request execution.
public struct RecordedRequestGroup: Sendable {
    /// The identity shared by the attempts in this group.
    public let requestID: RequestID

    /// Attempts in the order MockNetworkTransport received them.
    public let attempts: [RecordedRequest]
}

/// The mismatch reasons for one registered stub that was active for an unmatched request.
public struct StubMismatch: Sendable, Equatable {
    /// The stub's zero-based position in registration order.
    public let registrationIndex: Int

    /// Reasons its matcher rejected the received request.
    public let reasons: [RequestMismatchReason]
}

/// A mock transport or explicit-verification failure with privacy-safe diagnostics.
public enum NetworkTestSupportError: Error, LocalizedError, Sendable {
    /// No active registered stub matched the received transport attempt.
    case unmatchedRequest(receivedRequest: String, activeStubs: [StubMismatch])

    /// One or more finite stubs still had expected uses remaining.
    case finiteStubsNotConsumed([Int])

    /// The recorded attempt count differed from the expected matcher count.
    case requestCountMismatch(expected: Int, actual: Int)

    /// A recorded request failed the matcher at the specified zero-based position.
    case requestOrderMismatch(index: Int, reason: RequestMismatchReason)

    /// No recorded transport attempt observed cancellation.
    case cancellationNotObserved

    /// A response kind was incompatible with the request's data or download operation.
    case responseOperationMismatch

    /// A redirect simulation could not represent a participating request in Foundation and HTTP form.
    case redirectRequiresRepresentableRequest

    /// A human-readable description with sanitized request details.
    public var errorDescription: String? {
        switch self {
        case let .unmatchedRequest(receivedRequest, activeStubs):
            let stubs = activeStubs.map { mismatch in
                let reasons = mismatch.reasons.map(\.diagnosticDescription).joined(separator: ", ")
                return "stub[\(mismatch.registrationIndex)]: \(reasons)"
            }
            let available = stubs.isEmpty ? "none" : stubs.joined(separator: "; ")
            return "Unmatched mock request: \(receivedRequest). Active stubs: \(available)."
        case let .finiteStubsNotConsumed(indices):
            return "Finite mock stubs were not fully consumed: \(indices.map(String.init).joined(separator: ", "))."
        case let .requestCountMismatch(expected, actual):
            return "Recorded request count was \(actual); expected \(expected)."
        case let .requestOrderMismatch(index, reason):
            return "Recorded request at position \(index) did not match: \(reason.diagnosticDescription)."
        case .cancellationNotObserved:
            return "No mock transport attempt observed cancellation."
        case .responseOperationMismatch:
            return "The selected mock response is incompatible with the request operation."
        case .redirectRequiresRepresentableRequest:
            return "The mock transport could not represent a request involved in the redirect simulation "
                + "as both a Foundation URLRequest and an HTTPRequest."
        }
    }
}

/// An actor-backed transport for deterministic tests of the real Networking request pipeline.
///
/// The mock records each actual transport attempt, selects active stubs in registration order, and
/// fails unmatched requests itself. It never falls through to `URLSession`.
public actor MockNetworkTransport: NetworkTransport {
    private struct RegisteredStub: Sendable {
        let stub: NetworkStub
        var remainingUses: Int?
    }

    private var stubs: [RegisteredStub]
    private var recordings: [RecordedRequest] = []

    /// Creates a mock transport with an optional ordered set of stubs.
    public init(stubs: [NetworkStub] = []) {
        self.stubs = stubs.map { stub in
            let remaining: Int? =
                switch stub.consumption {
                case .once:
                    1
                case let .finite(count):
                    count
                case .always:
                    nil
                }
            return RegisteredStub(stub: stub, remainingUses: remaining)
        }
    }

    /// Registers a stub after all stubs already in the transport.
    public func register(_ stub: NetworkStub) {
        let remaining: Int? =
            switch stub.consumption {
            case .once:
                1
            case let .finite(count):
                count
            case .always:
                nil
            }
        stubs.append(RegisteredStub(stub: stub, remainingUses: remaining))
    }

    /// Returns every actual transport attempt in the order it reached the mock.
    public func recordedRequests() -> [RecordedRequest] {
        recordings
    }

    /// Groups recorded attempts by request ID, preserving first-seen group and attempt order.
    public func recordedRequestsByRequestID() -> [RecordedRequestGroup] {
        var requestIDs: [RequestID] = []
        var attemptsByID: [RequestID: [RecordedRequest]] = [:]
        for request in recordings {
            if attemptsByID[request.requestID] == nil {
                requestIDs.append(request.requestID)
            }
            attemptsByID[request.requestID, default: []].append(request)
        }
        return requestIDs.compactMap { requestID in
            guard let attempts = attemptsByID[requestID] else {
                return nil
            }

            return RecordedRequestGroup(requestID: requestID, attempts: attempts)
        }
    }

    /// Throws unless every finite stub has been consumed the configured number of times.
    public func verifyAllFiniteStubsConsumed() throws {
        let unconsumed = stubs.indices.filter { index in
            guard let remaining = stubs[index].remainingUses else {
                return false
            }

            return remaining > 0
        }
        guard unconsumed.isEmpty else {
            throw NetworkTestSupportError.finiteStubsNotConsumed(unconsumed)
        }
    }

    /// Verifies matchers against recorded attempts without changing stub matching or consumption.
    public func verifyRequestOrder(_ expected: [RequestMatcher]) throws {
        guard expected.count == recordings.count else {
            throw NetworkTestSupportError.requestCountMismatch(expected: expected.count, actual: recordings.count)
        }

        for index in expected.indices {
            if let reason = expected[index].mismatch(for: recordings[index]) {
                throw NetworkTestSupportError.requestOrderMismatch(index: index, reason: reason)
            }
        }
    }

    /// Throws unless at least one recorded transport attempt observed cancellation.
    public func verifyCancellationObserved() throws {
        guard recordings.contains(where: \.cancellationObserved) else {
            throw NetworkTestSupportError.cancellationNotObserved
        }
    }

    package func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        switch await executeWithMetrics(request) {
        case let .success(data, response, _, _):
            return (data, response)
        case let .failure(error, _, _, _):
            throw error
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, _, normalizedMetrics):
            throw RedirectError.tooManyRedirects(
                requestID: request.requestID,
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                attempts: [
                    AttemptMetrics(
                        requestID: request.requestID,
                        attemptNumber: request.attemptNumber,
                        normalizedMetrics: normalizedMetrics ?? NormalizedAttemptMetrics(),
                        outcome: .redirectLimitExceeded,
                        diagnosticReason: nil,
                        rawTaskMetrics: nil,
                    ),
                ],
            )
        }
    }

    package func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        guard request.operation != .download else {
            return .failure(
                error: TransportExecutionError.downloadRequiresFileBackedResult,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        switch await resolveScriptedAttempt(request, progress: progress) {
        case .startRejected:
            return .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: false)
        case let .delivered(outcome):
            switch outcome.body {
            case let .httpResponse(data, response):
                return .success(
                    data: data,
                    response: response,
                    rawTaskMetrics: nil,
                    normalizedMetrics: outcome.metrics,
                )
            case .download:
                return .failure(
                    error: NetworkTestSupportError.responseOperationMismatch,
                    rawTaskMetrics: nil,
                    didStartTask: true,
                    normalizedMetrics: outcome.metrics,
                )
            }
        case let .failed(error, normalizedMetrics):
            return .failure(
                error: error,
                rawTaskMetrics: nil,
                didStartTask: true,
                normalizedMetrics: normalizedMetrics,
            )
        case let .redirectLimitExceeded(limit):
            return .redirectLimitExceeded(
                maximumRedirects: limit.maximumRedirects,
                lastResponse: limit.lastResponse,
                rawTaskMetrics: nil,
                normalizedMetrics: limit.metrics,
            )
        }
    }

    package func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        switch await resolveScriptedAttempt(request, progress: progress) {
        case .startRejected:
            .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: false)
        case let .delivered(outcome):
            switch outcome.body {
            case let .download(data, response):
                deliverScriptedDownload(data, response: response, outcome: outcome)
            case .httpResponse:
                .failure(
                    error: NetworkTestSupportError.responseOperationMismatch,
                    rawTaskMetrics: nil,
                    didStartTask: true,
                    normalizedMetrics: outcome.metrics,
                )
            }
        case let .failed(error, normalizedMetrics):
            .failure(
                error: error,
                rawTaskMetrics: nil,
                didStartTask: true,
                normalizedMetrics: normalizedMetrics,
            )
        case let .redirectLimitExceeded(limit):
            .redirectLimitExceeded(
                maximumRedirects: limit.maximumRedirects,
                lastResponse: limit.lastResponse,
                rawTaskMetrics: nil,
                normalizedMetrics: limit.metrics,
            )
        }
    }

    /// Materializes the response bytes of one delivered scripted download.
    ///
    /// The file is discarded again when the attempt was cancelled after the transport produced it, so
    /// a cancelled download never hands ownership to the caller.
    private func deliverScriptedDownload(
        _ data: Data,
        response: HTTPResponse,
        outcome: ScriptedExecutionOutcome,
    ) -> NetworkTransportDownloadResult {
        do {
            let file = try Self.makeLibraryOwnedDownload(data)
            guard !Task.isCancelled else {
                file.discard()
                markCancellationObserved(at: outcome.recordingIndex)
                return .failure(
                    error: CancellationError(),
                    rawTaskMetrics: nil,
                    didStartTask: true,
                    normalizedMetrics: outcome.metrics,
                )
            }

            return .success(
                file: file,
                response: response,
                rawTaskMetrics: nil,
                normalizedMetrics: outcome.metrics,
            )
        } catch {
            return .failure(
                error: error,
                rawTaskMetrics: nil,
                didStartTask: true,
                normalizedMetrics: outcome.metrics,
            )
        }
    }

    /// The resolved terminal response body of one scripted attempt.
    private enum ScriptedBody: Sendable {
        /// In-memory bytes delivered to a data or upload operation.
        case httpResponse(data: Data, response: HTTPResponse)

        /// Bytes delivered through the library-owned download-file lifecycle.
        case download(data: Data, response: HTTPResponse)
    }

    /// The terminal result of one scripted attempt, including the recording used for cancellation.
    private struct ScriptedExecutionOutcome: Sendable {
        let body: ScriptedBody
        let metrics: NormalizedAttemptMetrics?
        let recordingIndex: Int
    }

    /// The terminal state of one mock transport attempt.
    private enum ScriptedAttemptResolution: Sendable {
        /// The attempt start was rejected, so the mock recorded nothing and consumed no stub.
        case startRejected

        /// The attempt resolved its terminal response.
        case delivered(ScriptedExecutionOutcome)

        /// The attempt failed after its start, retaining the selected stub's supplied metrics when a
        /// stub was selected before the failure.
        case failed(error: any Error, normalizedMetrics: NormalizedAttemptMetrics?)

        /// The attempt exhausted the redirect policy's follow budget.
        case redirectLimitExceeded(StubRedirectLimitExceeded)
    }

    /// The per-attempt redirect limit reached while resolving one scripted redirect chain.
    private struct StubRedirectLimitExceeded: Error, Sendable {
        let maximumRedirects: UInt
        let lastResponse: HTTPResponse?
        let metrics: NormalizedAttemptMetrics?
    }

    /// Commits one attempt start, then records and consumes a stub and executes its scripted actions.
    ///
    /// The progress reporter commits the start before the mock records the request or consumes the
    /// selected stub, because both model transport work that must not happen for an attempt whose
    /// start was rejected. Failures retain the selected stub's supplied metrics so attempt histories
    /// and failed-attempt events keep the diagnostics the stub described, while raw task metrics stay
    /// empty because no Foundation task produced them.
    private func resolveScriptedAttempt(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> ScriptedAttemptResolution {
        guard progress.startAttempt(
            attemptNumber: request.attemptNumber,
            expectedBytesToSend: expectedRequestBodyByteCount(request.execution),
        ) else {
            return .startRejected
        }

        let recordingIndex: Int
        let stub: NetworkStub
        do {
            (recordingIndex, stub) = try selectResponse(for: request)
        } catch {
            return .failed(error: error, normalizedMetrics: nil)
        }

        do {
            try await pauseThroughScriptedActions(stub, progress: progress)
            var state = RedirectEvaluationState()
            let body = try resolveTerminalResponse(
                stub.response,
                request: request,
                metrics: stub.metrics,
                state: &state,
                currentRequest: nil,
            )
            guard !Task.isCancelled else {
                markCancellationObserved(at: recordingIndex)
                return .failed(error: CancellationError(), normalizedMetrics: stub.metrics)
            }

            return .delivered(
                ScriptedExecutionOutcome(
                    body: body,
                    metrics: stub.metrics,
                    recordingIndex: recordingIndex,
                ),
            )
        } catch let limit as StubRedirectLimitExceeded {
            return .redirectLimitExceeded(limit)
        } catch {
            guard Task.isCancelled else {
                // A stub can script any error, including `CancellationError`, but only the task that
                // executes the mock can establish that cancellation reached the transport. A
                // scripted cancellation failure stays an ordinary terminal transport error.
                return .failed(error: error, normalizedMetrics: stub.metrics)
            }

            markCancellationObserved(at: recordingIndex)
            return .failed(error: CancellationError(), normalizedMetrics: stub.metrics)
        }
    }

    /// Suspends at every scripted pause point and publishes the update that follows it.
    ///
    /// A stub reaches one pause point before each scripted update and one further pause point
    /// before it produces its terminal response, so a stub without scripted updates reaches exactly
    /// one pause point.
    private func pauseThroughScriptedActions(
        _ stub: NetworkStub,
        progress: NetworkProgressReporter,
    ) async throws {
        let latency = stub.latency
        for (index, update) in stub.progress.enumerated() {
            try await latency?.suspend(at: index + 1)
            switch update {
            case let .upload(bytesSent, expectedBytesToSend):
                progress.updateUpload(bytesSent: bytesSent, expectedBytesToSend: expectedBytesToSend)
            case let .download(bytesReceived, expectedBytesToReceive):
                progress.updateDownload(
                    bytesReceived: bytesReceived,
                    expectedBytesToReceive: expectedBytesToReceive,
                )
            }
        }
        try await latency?.suspend(at: stub.progress.count + 1)
    }

    /// Resolves a scripted response, evaluating redirect proposals with the production policy.
    ///
    /// Redirect proposals stay inside the current attempt: they consume no further stub, never
    /// change the attempt number, and produce the same decisions, limits, and lifecycle events as
    /// live URLSession execution. A rejected proposal ends the attempt with the redirect response,
    /// and exceeding the policy limit throws an internal marker error for the caller to report.
    /// A proposal whose Foundation request has no HTTP form fails the attempt with
    /// `NetworkTestSupportError.redirectRequiresRepresentableRequest` before the policy evaluates
    /// it, so a decision can never appear without its `redirectDecision` event.
    private func resolveTerminalResponse(
        _ response: StubResponse,
        request: TransportRequest,
        metrics: NormalizedAttemptMetrics?,
        state: inout RedirectEvaluationState,
        currentRequest: URLRequest?,
    ) throws -> ScriptedBody {
        switch response {
        case let .httpResponse(data, httpResponse):
            return .httpResponse(data: data, response: httpResponse)
        case let .download(data, httpResponse):
            return .download(data: data, response: httpResponse)
        case let .failure(error):
            throw error
        case let .redirect(proposals, followedBy):
            var activeRequest: URLRequest
            if let currentRequest {
                activeRequest = currentRequest
            } else {
                guard let derivedRequest = makeURLRequest(
                    request,
                    assumesHTTP3Capable: request.assumesHTTP3Capable,
                ) else {
                    throw NetworkTestSupportError.redirectRequiresRepresentableRequest
                }

                activeRequest = derivedRequest
            }

            for proposal in proposals {
                guard let proposedHTTPRequest = proposal.proposedRequest.httpRequest else {
                    throw NetworkTestSupportError.redirectRequiresRepresentableRequest
                }

                let outcome = evaluateRedirectProposal(
                    state: &state,
                    policy: request.redirectPolicy,
                    currentRequest: activeRequest,
                    proposedRequest: proposal.proposedRequest,
                    httpResponse: proposal.response,
                    requestID: request.requestID,
                    requestContext: request.requestContext,
                    attemptNumber: request.attemptNumber,
                    proposedHTTPRequest: proposedHTTPRequest,
                    eventExecution: request.eventExecution,
                )
                switch outcome {
                case .follow:
                    activeRequest = proposal.proposedRequest
                case .reject:
                    return Self.scriptedBody(
                        data: proposal.body,
                        response: proposal.response,
                        operation: request.operation,
                    )
                case let .limitExceeded(limit):
                    throw StubRedirectLimitExceeded(
                        maximumRedirects: limit.maximumRedirects,
                        lastResponse: limit.lastResponse,
                        metrics: metrics,
                    )
                }
            }

            return try resolveTerminalResponse(
                followedBy,
                request: request,
                metrics: metrics,
                state: &state,
                currentRequest: activeRequest,
            )
        }
    }

    /// Describes response bytes the way the request operation delivers them.
    private static func scriptedBody(
        data: Data,
        response: HTTPResponse,
        operation: EndpointOperation,
    ) -> ScriptedBody {
        operation == .download
            ? .download(data: data, response: response)
            : .httpResponse(data: data, response: response)
    }

    private func selectResponse(for request: TransportRequest) throws -> (Int, NetworkStub) {
        let recordingIndex = recordings.count
        let recorded = RecordedRequest(
            httpRequest: request.httpRequest,
            preparedBody: request.body,
            requestID: request.requestID,
            attemptNumber: request.attemptNumber,
            requestContext: request.requestContext,
        )
        recordings.append(recorded)

        var activeMismatches: [StubMismatch] = []
        var selectedIndex: Int?
        for index in stubs.indices {
            guard stubs[index].remainingUses != 0 else {
                continue
            }

            if let reason = stubs[index].stub.matcher.mismatch(for: recorded) {
                activeMismatches.append(StubMismatch(registrationIndex: index, reasons: [reason]))
            } else {
                selectedIndex = index
                break
            }
        }

        guard let selectedIndex else {
            if Task.isCancelled {
                markCancellationObserved(at: recordingIndex)
                throw CancellationError()
            }
            let received = Self.safeRequestDescription(recorded)
            throw NetworkTestSupportError.unmatchedRequest(
                receivedRequest: received,
                activeStubs: activeMismatches,
            )
        }

        if let remaining = stubs[selectedIndex].remainingUses {
            stubs[selectedIndex].remainingUses = remaining - 1
        }
        if Task.isCancelled {
            markCancellationObserved(at: recordingIndex)
            throw CancellationError()
        }
        return (recordingIndex, stubs[selectedIndex].stub)
    }

    private func markCancellationObserved(at index: Int) {
        recordings[index] = recordings[index].observingCancellation()
    }

    private static func safeRequestDescription(_ request: RecordedRequest) -> String {
        let method = NetworkPrivacySanitizer.escape(String(describing: request.httpRequest.method))
        let url = NetworkPrivacySanitizer.requestURLShape(request.httpRequest)
        let headerNames = Set(request.httpRequest.headerFields.map { $0.name.canonicalName.lowercased() })
            .union(NetworkPrivacySanitizer.mandatorySensitiveHeaderNames)
        let headers = NetworkPrivacySanitizer.headers(
            request.httpRequest.headerFields,
            sensitiveHeaderNames: headerNames,
        )
        let bodyDescription: String
        switch request.preparedBody {
        case .none:
            bodyDescription = "none"
        case let .data(data):
            bodyDescription = "data(\(data.count) bytes)"
        case .file:
            let size = request.preparedBodyFileSize.map(String.init) ?? "unknown"
            bodyDescription = "file(\(size) bytes)"
        }
        return "method=\(method) url=\(url) headers=\(headers) body=\(bodyDescription) " +
            "request_id=\(request.requestID.rawValue.uuidString) attempt=\(request.attemptNumber)"
    }

    private static func makeLibraryOwnedDownload(_ data: Data) throws -> DownloadedFileStorage {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-test-support-\(UUID().uuidString)",
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            return try DownloadedFileStorage.adopt(temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

extension RequestMismatchReason {
    fileprivate var diagnosticDescription: String {
        switch self {
        case .method:
            "method mismatch"
        case .url:
            "URL mismatch"
        case .path:
            "path mismatch"
        case .query:
            "query mismatch"
        case .headers:
            "header mismatch"
        case .body:
            "body mismatch"
        case .semanticJSONBody:
            "semantic JSON body mismatch"
        case .requestContext:
            "request context mismatch"
        case .attemptNumber:
            "attempt number mismatch"
        case .customMatcher:
            "custom matcher returned false"
        case let .allOf(reasons):
            "and composition failed (child mismatches: \(reasons.map(\.diagnosticDescription).joined(separator: ", ")))"
        case let .anyOf(reasons):
            "none of [\(reasons.map(\.diagnosticDescription).joined(separator: ", "))]"
        case .negatedMatcherMatched:
            "negated matcher matched"
        }
    }
}
