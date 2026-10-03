//
//  SnapshotRequestProjections.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

#if !os(visionOS)
import Foundation
import HTTPTypes
import Networking

/// A privacy-safe rendering of one HTTP request.
///
/// The URL shape and header rendering reuse the package-internal sanitizer that production
/// diagnostics use, so query values and sensitive headers are redacted before they can reach a
/// snapshot.
struct SnapshotHTTPRequest: Sendable, Equatable {
    let method: String
    let url: String
    let headers: String

    init(_ request: HTTPRequest, renderer: SnapshotProjectionRenderer) {
        method = request.method.rawValue
        url = NetworkPrivacySanitizer.requestURLShape(request)
        headers = NetworkPrivacySanitizer.headers(
            request.headerFields,
            sensitiveHeaderNames: renderer.sensitiveHeaderNames,
        )
    }
}

/// A privacy-safe rendering of one HTTP response.
struct SnapshotHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: String

    init(_ response: HTTPResponse, renderer: SnapshotProjectionRenderer) {
        statusCode = response.status.code
        headers = NetworkPrivacySanitizer.headers(
            response.headerFields,
            sensitiveHeaderNames: renderer.sensitiveHeaderNames,
        )
    }
}

/// A bounded rendering of a prepared request body that never reads file-backed bytes.
enum SnapshotPreparedBody: Sendable, Equatable {
    case none
    case data(byteCount: Int)
    case file(location: String, byteCount: UInt64?)

    init(_ body: PreparedRequestBody, fileSize: UInt64?, renderer: SnapshotProjectionRenderer) {
        switch body {
        case .none:
            self = .none
        case let .data(data):
            self = .data(byteCount: data.count)
        case let .file(url):
            self = .file(location: renderer.location(url), byteCount: fileSize)
        }
    }
}

/// A rendering of the library-owned normalized metrics for one attempt.
struct SnapshotNormalizedMetrics: Sendable, Equatable {
    let duration: String
    let redirectCount: Int?
    let requestBodyBytesSent: Int64?
    let responseBodyBytesReceived: Int64?
    let networkProtocolName: String?
    let isReusedConnection: Bool?
    let resourceFetchType: URLSessionTaskMetrics.ResourceFetchType?

    init(_ metrics: NormalizedAttemptMetrics, renderer: SnapshotProjectionRenderer) {
        duration = metrics.duration.map(renderer.duration) ?? SnapshotPlaceholder.absent
        redirectCount = metrics.redirectCount
        requestBodyBytesSent = metrics.requestBodyBytesSent
        responseBodyBytesReceived = metrics.responseBodyBytesReceived
        networkProtocolName = metrics.networkProtocolName
        isReusedConnection = metrics.isReusedConnection
        resourceFetchType = metrics.resourceFetchType
    }
}

/// A rendering of one attempt's identity, outcome, and normalized diagnostics.
struct SnapshotAttemptMetrics: Sendable, Equatable {
    let requestID: String
    let attemptNumber: UInt
    let outcome: String
    let diagnosticReason: String
    let normalizedMetrics: SnapshotNormalizedMetrics
    let rawTaskMetrics: String

    init(_ metrics: AttemptMetrics, renderer: SnapshotProjectionRenderer) {
        requestID = renderer.requestID(metrics.requestID)
        attemptNumber = metrics.attemptNumber
        outcome = String(describing: metrics.outcome)
        diagnosticReason = renderer.diagnosticReason(metrics.diagnosticReason)
        normalizedMetrics = SnapshotNormalizedMetrics(metrics.normalizedMetrics, renderer: renderer)
        rawTaskMetrics = renderer.rawTaskMetrics(metrics.rawTaskMetrics)
    }
}

/// A rendering of one recorded transport attempt.
struct SnapshotRecordedRequest: Sendable, Equatable {
    let request: SnapshotHTTPRequest
    let body: SnapshotPreparedBody
    let requestID: String
    let attemptNumber: UInt
    let requestContext: [RequestContextDiagnosticEntry]
    let cancellationObserved: Bool

    init(_ recorded: RecordedRequest, renderer: SnapshotProjectionRenderer) {
        request = SnapshotHTTPRequest(recorded.httpRequest, renderer: renderer)
        body = SnapshotPreparedBody(
            recorded.preparedBody,
            fileSize: recorded.preparedBodyFileSize,
            renderer: renderer,
        )
        requestID = renderer.requestID(recorded.requestID)
        attemptNumber = recorded.attemptNumber
        requestContext = recorded.requestContext.diagnosticRepresentation
        cancellationObserved = recorded.cancellationObserved
    }
}
#endif
