//
//  SnapshotResponseProjections.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Networking

/// A rendering of a retained response-body prefix that reports only bounded metadata.
///
/// Retained bytes can contain credentials, tokens, or personal data, so a snapshot records their
/// sizes and truncation state instead of their contents.
struct SnapshotRetainedBody: Sendable, Equatable {
    let byteCount: Int
    let originalByteCount: Int64
    let isTruncated: Bool

    init(_ body: RetainedBody) {
        byteCount = body.data.count
        originalByteCount = body.originalByteCount
        isTruncated = body.isTruncated
    }
}

/// A rendering of a library-owned downloaded file that never transfers cleanup ownership.
///
/// The projection reads the package-internal storage location, which is observational. Reading the
/// public URL would hand cleanup responsibility to the caller as a side effect of snapshotting.
struct SnapshotDownloadedFile: Sendable, Equatable {
    let location: String

    init(_ file: DownloadedFile, renderer: SnapshotProjectionRenderer) {
        location = renderer.location(file.ownership.url)
    }
}

/// A rendering of the decoded value carried by a response.
enum SnapshotResponseValue<Value: Sendable>: Sendable {
    case value(Value)
    case downloadedFile(SnapshotDownloadedFile)

    init(_ value: Value, renderer: SnapshotProjectionRenderer) {
        if let file = value as? DownloadedFile {
            self = .downloadedFile(SnapshotDownloadedFile(file, renderer: renderer))
        } else {
            self = .value(value)
        }
    }
}

/// A rendering of one decoded response with its identity and attempt history.
struct SnapshotResponse<Value: Sendable>: Sendable {
    let value: SnapshotResponseValue<Value>
    let httpResponse: SnapshotHTTPResponse
    let requestID: String
    let attempts: [SnapshotAttemptMetrics]
    let retainedBody: SnapshotRetainedBody?

    init(_ response: Response<Value>, renderer: SnapshotProjectionRenderer) {
        value = SnapshotResponseValue(response.value, renderer: renderer)
        httpResponse = SnapshotHTTPResponse(response.httpResponse, renderer: renderer)
        requestID = renderer.requestID(response.requestID)
        attempts = response.attempts.map { SnapshotAttemptMetrics($0, renderer: renderer) }
        retainedBody = response.retainedBody.map(SnapshotRetainedBody.init)
    }
}
