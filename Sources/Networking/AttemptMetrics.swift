//
//  AttemptMetrics.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// The final disposition of one actual transport task.
public enum AttemptOutcome: Sendable, Equatable, Hashable {
    /// The transport task failed before returning an HTTP response.
    case transportFailure

    /// The response passed validation.
    case acceptedResponse

    /// The response was rejected by the configured validation policy.
    case validationRejection
}

/// Normalized diagnostics for a single transport task.
public struct NormalizedAttemptMetrics: Sendable, Equatable, Hashable {
    /// The elapsed task duration reported by Foundation, when available.
    public let duration: Duration?

    /// The number of redirects reported for the task, when available.
    public let redirectCount: Int?

    /// The total number of request body bytes transferred across task transactions.
    public let requestBodyBytesSent: Int64?

    /// The total number of response body bytes transferred across task transactions.
    public let responseBodyBytesReceived: Int64?

    /// The negotiated protocol reported by the task's final transaction, when available.
    public let networkProtocolName: String?

    /// Whether the task's final transaction reused a connection, when available.
    public let isReusedConnection: Bool?

    /// How the task's final transaction fetched its resource, when available.
    public let resourceFetchType: URLSessionTaskMetrics.ResourceFetchType?

    package init(
        duration: Duration? = nil,
        redirectCount: Int? = nil,
        transactions: [AttemptTransactionMetrics] = [],
    ) {
        self.duration = duration
        self.redirectCount = redirectCount
        requestBodyBytesSent = Self.total(transactions.map(\.requestBodyBytesSent))
        responseBodyBytesReceived = Self.total(transactions.map(\.responseBodyBytesReceived))

        if let finalTransaction = transactions.last {
            networkProtocolName = finalTransaction.networkProtocolName
            isReusedConnection = finalTransaction.isReusedConnection
            resourceFetchType = finalTransaction.resourceFetchType
        } else {
            networkProtocolName = nil
            isReusedConnection = nil
            resourceFetchType = nil
        }
    }

    package init(taskMetrics: URLSessionTaskMetrics?) {
        guard let taskMetrics else {
            self.init()
            return
        }

        let durationSeconds = taskMetrics.taskInterval.duration
        let duration = durationSeconds.isFinite && durationSeconds >= 0
            ? Duration.seconds(durationSeconds)
            : nil
        let transactions = taskMetrics.transactionMetrics.map { transaction in
            AttemptTransactionMetrics(
                requestBodyBytesSent: transaction.countOfRequestBodyBytesSent,
                responseBodyBytesReceived: transaction.countOfResponseBodyBytesReceived,
                networkProtocolName: transaction.networkProtocolName,
                isReusedConnection: transaction.isReusedConnection,
                resourceFetchType: transaction.resourceFetchType,
            )
        }

        self.init(
            duration: duration,
            redirectCount: taskMetrics.redirectCount,
            transactions: transactions,
        )
    }

    private static func total(_ values: [Int64?]) -> Int64? {
        guard values.isEmpty == false else {
            return nil
        }

        var total: Int64 = 0
        for value in values {
            guard let value else {
                return nil
            }

            let (nextTotal, overflow) = total.addingReportingOverflow(value)
            guard overflow == false else {
                return nil
            }

            total = nextTotal
        }
        return total
    }
}

/// Identity, diagnostics, and final disposition for one transport task.
public struct AttemptMetrics: Sendable, Equatable, Hashable {
    /// The identity of the logical execution that created this task.
    public let requestID: RequestID

    /// The one-based position of this task within its logical execution.
    public let attemptNumber: UInt

    /// Normalized task diagnostics with stable library-owned field names.
    public let normalizedMetrics: NormalizedAttemptMetrics

    /// The final disposition of the task's response or transport operation.
    public let outcome: AttemptOutcome

    /// A diagnostic explanation supplied by validation or transport, when available.
    public let diagnosticReason: String?

    /// The complete Foundation metrics value collected for this task, when available.
    public let rawTaskMetrics: URLSessionTaskMetrics?

    package init(
        requestID: RequestID,
        attemptNumber: UInt,
        normalizedMetrics: NormalizedAttemptMetrics,
        outcome: AttemptOutcome,
        diagnosticReason: String?,
        rawTaskMetrics: URLSessionTaskMetrics?,
    ) {
        self.requestID = requestID
        self.attemptNumber = attemptNumber
        self.normalizedMetrics = normalizedMetrics
        self.outcome = outcome
        self.diagnosticReason = diagnosticReason
        self.rawTaskMetrics = rawTaskMetrics
    }
}

package struct AttemptTransactionMetrics: Sendable {
    let requestBodyBytesSent: Int64?
    let responseBodyBytesReceived: Int64?
    let networkProtocolName: String?
    let isReusedConnection: Bool?
    let resourceFetchType: URLSessionTaskMetrics.ResourceFetchType?
}

package enum NetworkTransportResult: Sendable {
    case success(data: Data, response: HTTPResponse, rawTaskMetrics: URLSessionTaskMetrics?)
    case failure(error: any Error, rawTaskMetrics: URLSessionTaskMetrics?, didStartTask: Bool)
}
