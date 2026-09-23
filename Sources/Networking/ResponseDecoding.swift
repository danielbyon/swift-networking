//
//  ResponseDecoding.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// A strategy that converts response bytes and metadata into a sendable output value.
public struct ResponseDecoding<Output: Sendable>: Sendable {
    private let decodeValue: @Sendable (Data, HTTPResponse) throws -> Output

    package init(decode: @escaping @Sendable (Data, HTTPResponse) throws -> Output) {
        decodeValue = decode
    }

    package func decode(_ data: Data, response: HTTPResponse) throws -> Output {
        try decodeValue(data, response)
    }
}

extension ResponseDecoding where Output == Data {
    /// Returns the response bytes unchanged.
    public static var data: Self {
        Self { data, _ in data }
    }
}
