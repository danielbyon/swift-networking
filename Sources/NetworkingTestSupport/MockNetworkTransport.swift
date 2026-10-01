//
//  MockNetworkTransport.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
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

    /// Creates a stub with immutable matching, response, and consumption configuration.
    ///
    /// - Throws: `ConfigurationError.finiteConsumptionMustBePositive` when the count is zero or less.
    public init(
        matching matcher: RequestMatcher,
        response: StubResponse,
        consumption: StubConsumption = .once,
    ) throws {
        if case let .finite(count) = consumption, count <= 0 {
            throw ConfigurationError.finiteConsumptionMustBePositive
        }
        self.matcher = matcher
        self.response = response
        self.consumption = consumption
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
        let (recordingIndex, response) = try selectResponse(for: request)
        if Task.isCancelled {
            markCancellationObserved(at: recordingIndex)
            throw CancellationError()
        }
        switch response {
        case let .httpResponse(data, httpResponse):
            return (data, httpResponse)
        case let .failure(error):
            throw error
        case .download:
            throw NetworkTestSupportError.responseOperationMismatch
        }
    }

    package func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        guard progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil) else {
            return .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: false)
        }

        do {
            let (recordingIndex, response) = try selectResponse(for: request)
            let data: Data
            let httpResponse: HTTPResponse
            switch response {
            case let .download(downloadData, response):
                data = downloadData
                httpResponse = response
            case let .failure(error):
                throw error
            case .httpResponse:
                throw NetworkTestSupportError.responseOperationMismatch
            }
            let file = try Self.makeLibraryOwnedDownload(data)
            guard !Task.isCancelled else {
                file.discard()
                markCancellationObserved(at: recordingIndex)
                throw CancellationError()
            }

            return .success(file: file, response: httpResponse, rawTaskMetrics: nil)
        } catch {
            return .failure(error: error, rawTaskMetrics: nil, didStartTask: true)
        }
    }

    private func selectResponse(for request: TransportRequest) throws -> (Int, StubResponse) {
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
        return (recordingIndex, stubs[selectedIndex].stub.response)
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
