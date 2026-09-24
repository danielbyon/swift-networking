//
//  BodyRetentionPolicy.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Controls how many bytes of a received response body are retained for diagnostics.
public enum BodyRetentionPolicy: Sendable {
    /// Do not retain response body bytes.
    case none

    /// Retain all response body bytes.
    case unlimited

    /// Retain at most the first `byteCount` bytes of the response body.
    ///
    /// A zero or negative value retains an empty prefix.
    case upTo(Int)

    package func retain(_ body: Data) -> RetainedBody? {
        switch self {
        case .none:
            return nil
        case .unlimited:
            return RetainedBody(data: body, originalByteCount: Int64(body.count))
        case let .upTo(byteCount):
            let retainedByteCount = min(max(0, byteCount), body.count)
            return RetainedBody(
                data: Data(body.prefix(retainedByteCount)),
                originalByteCount: Int64(body.count),
            )
        }
    }
}

/// A retained response-body prefix and metadata describing the original body.
public struct RetainedBody: Sendable, Equatable, Hashable {
    /// The retained response-body bytes.
    public let data: Data

    /// The exact size of the original response body in bytes.
    public let originalByteCount: Int64

    /// Whether the retained data omits any bytes from the original response body.
    public let isTruncated: Bool

    package init(data: Data, originalByteCount: Int64) {
        self.data = data
        self.originalByteCount = originalByteCount
        isTruncated = Int64(data.count) < originalByteCount
    }
}
