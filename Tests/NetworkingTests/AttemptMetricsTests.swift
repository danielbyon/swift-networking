//
//  AttemptMetricsTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct AttemptMetricsTests {
    @Test("Normalized byte counts sum task transactions and other fields use the final transaction")
    func normalizedMetricsUseTaskAndFinalTransactionValues() {
        let metrics = NormalizedAttemptMetrics(
            duration: .seconds(2.5),
            redirectCount: 1,
            transactions: [
                AttemptTransactionMetrics(
                    requestBodyBytesSent: 11,
                    responseBodyBytesReceived: 17,
                    networkProtocolName: "h2",
                    isReusedConnection: false,
                    resourceFetchType: .networkLoad,
                ),
                AttemptTransactionMetrics(
                    requestBodyBytesSent: 13,
                    responseBodyBytesReceived: 19,
                    networkProtocolName: "h3",
                    isReusedConnection: true,
                    resourceFetchType: URLSessionTaskMetrics.ResourceFetchType(rawValue: 3),
                ),
            ],
        )

        #expect(metrics.duration == .seconds(2.5))
        #expect(metrics.redirectCount == 1)
        #expect(metrics.requestBodyBytesSent == 24)
        #expect(metrics.responseBodyBytesReceived == 36)
        #expect(metrics.networkProtocolName == "h3")
        #expect(metrics.isReusedConnection == true)
        #expect(metrics.resourceFetchType?.rawValue == 3)
    }

    @Test("Absent Foundation task metrics leave every normalized value absent")
    func absentTaskMetricsNormalizeToNil() {
        #expect(NormalizedAttemptMetrics(taskMetrics: nil) == NormalizedAttemptMetrics())
    }

    @Test("Metrics arriving after task completion are retained until collection finishes")
    func metricsArrivingAfterTaskCompletionAreRetained() {
        var state = TaskMetricsCollectionState<Int>()

        state.taskDidComplete()
        #expect(state.result == nil)

        state.finishCollecting(42)
        #expect(state.result == .some(.some(42)))
    }

    @Test("Metrics arriving before task completion are retained until the task finishes")
    func metricsArrivingBeforeTaskCompletionAreRetained() {
        var state = TaskMetricsCollectionState<Int>()

        state.finishCollecting(42)
        #expect(state.result == nil)

        state.taskDidComplete()
        #expect(state.result == .some(.some(42)))
    }

    @Test("A completed metrics collection can report no metrics")
    func completedMetricsCollectionCanBeAbsent() {
        var state = TaskMetricsCollectionState<Int>()

        state.taskDidComplete()
        state.finishCollecting(nil)

        #expect(state.result == .some(nil))
    }

    @Test("Success exposes one accepted attempt with the logical request identity")
    func successExposesAcceptedAttempt() async throws {
        let requestID = RequestID(rawValue: UUID())
        let client = try NetworkClient(
            transport: LegacySuccessTransport(),
            configuration: .init().withRequestIDGenerator(AttemptRequestIDGenerator(requestID: requestID)),
        )

        let response = try await client.send(makeRequest())

        #expect(response.requestID == requestID)
        #expect(response.attempts.count == 1)
        #expect(response.attempts[0].requestID == requestID)
        #expect(response.attempts[0].attemptNumber == 1)
        #expect(response.attempts[0].outcome == .acceptedResponse)
    }

    @Test("Validation rejection exposes its attempt and reason")
    func validationFailureExposesRejectingAttempt() async throws {
        let policy = ResponseValidationPolicy.custom(validate: { _ in
            .reject(reason: "diagnostic rejection")
        })
        let client = try NetworkClient(
            transport: LegacySuccessTransport(statusCode: 503),
            configuration: .init().withResponseValidationPolicy(policy),
        )

        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected response validation to reject the response")
        } catch let error as ResponseValidationError {
            #expect(error.attempts.count == 1)
            #expect(error.attempts[0].attemptNumber == 1)
            #expect(error.attempts[0].outcome == .validationRejection)
            #expect(error.attempts[0].diagnosticReason == "diagnostic rejection")
            #expect(error.reason == "diagnostic rejection")
        }
    }

    @Test("Legacy transport adapter preserves the thrown error and reports no raw metrics")
    func legacyTransportAdapterPreservesThrownError() async throws {
        let transport = LegacyFailureTransport()
        let request = try makeTransportRequest()

        switch await transport.executeWithMetrics(request) {
        case .success:
            Issue.record("Expected the legacy transport error to be captured")
        case .redirectLimitExceeded:
            Issue.record("Did not expect a redirect limit result")
        case let .failure(error, rawTaskMetrics, didStartTask):
            #expect(error as? AttemptTransportFailure == .expected)
            #expect(rawTaskMetrics == nil)
            #expect(didStartTask)
        }
    }

    @Test("Metrics-aware transport failures propagate the original error unchanged")
    func metricsAwareTransportFailurePreservesOriginalError() async throws {
        let transport = MetricsFailureTransport()
        let request = try makeTransportRequest()

        switch await transport.executeWithMetrics(request) {
        case .success:
            Issue.record("Expected the metrics-aware transport to report its failure")
        case .redirectLimitExceeded:
            Issue.record("Did not expect a redirect limit result")
        case let .failure(error, rawTaskMetrics, didStartTask):
            #expect(error as? AttemptTransportFailure == .expected)
            #expect(rawTaskMetrics == nil)
            #expect(didStartTask)
        }

        let client = try NetworkClient(transport: transport)
        do {
            _ = try await client.send(makeRequest())
            Issue.record("Expected the original transport error to propagate")
        } catch let error as AttemptTransportFailure {
            #expect(error == .expected)
        }
    }

    @Test("Response equality and hashing include attempt history")
    func responseEqualityAndHashingIncludeAttempts() {
        let requestID = RequestID(rawValue: UUID())
        let first = AttemptMetrics(
            requestID: requestID,
            attemptNumber: 1,
            normalizedMetrics: NormalizedAttemptMetrics(),
            outcome: .acceptedResponse,
            diagnosticReason: nil,
            rawTaskMetrics: nil,
        )
        let second = AttemptMetrics(
            requestID: requestID,
            attemptNumber: 2,
            normalizedMetrics: NormalizedAttemptMetrics(),
            outcome: .acceptedResponse,
            diagnosticReason: nil,
            rawTaskMetrics: nil,
        )
        #expect(first != second)
        #expect(Set([first, second]).count == 2)

        let httpResponse = HTTPResponse(status: .init(code: 200))
        let firstResponse = Response(
            value: Data([0x01]),
            httpResponse: httpResponse,
            requestID: requestID,
            attempts: [first],
        )
        let secondResponse = Response(
            value: Data([0x01]),
            httpResponse: httpResponse,
            requestID: requestID,
            attempts: [second],
        )

        #expect(firstResponse != secondResponse)
        #expect(Set([firstResponse, secondResponse]).count == 2)
    }

    private func makeTransportRequest() throws -> TransportRequest {
        let url = try #require(URL(string: "https://example.com/attempt"))
        return TransportRequest(httpRequest: HTTPRequest(method: .get, url: url), body: .none)
    }

    private func makeRequest() throws -> Request<Data> {
        let url = try #require(URL(string: "https://example.com/attempt"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        return Request(endpoint: endpoint)
    }
}

private struct AttemptRequestIDGenerator: RequestIDGenerator {
    let requestID: RequestID

    func generateRequestID() -> RequestID {
        requestID
    }
}

private enum AttemptTransportFailure: Error, Sendable, Equatable {
    case expected
}

private actor LegacyFailureTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw AttemptTransportFailure.expected
    }
}

private struct MetricsFailureTransport: NetworkTransport {
    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw AttemptTransportFailure.expected
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        progress.startAttempt(
            attemptNumber: request.attemptNumber,
            expectedBytesToSend: nil,
        )
        return .failure(
            error: AttemptTransportFailure.expected,
            rawTaskMetrics: nil,
            didStartTask: true,
        )
    }
}

private actor LegacySuccessTransport: NetworkTransport {
    private let statusCode: Int

    init(statusCode: Int = 200) {
        self.statusCode = statusCode
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        (Data([0x01]), HTTPResponse(status: .init(code: statusCode)))
    }
}
