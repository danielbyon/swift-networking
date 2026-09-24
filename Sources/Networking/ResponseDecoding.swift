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
    private let decodeValue: @Sendable (
        Data,
        HTTPResponse,
        JSONDecoderConfiguration,
        JSONDecoderConfiguration,
    ) throws -> Output

    package let inferredAccept: String?

    package init(
        decode: @escaping @Sendable (Data, HTTPResponse) throws -> Output,
        inferredAccept: String? = nil,
    ) {
        decodeValue = { data, response, _, _ in
            try decode(data, response)
        }
        self.inferredAccept = inferredAccept
    }

    private init(
        jsonDecode: @escaping @Sendable (
            Data,
            HTTPResponse,
            JSONDecoderConfiguration,
            JSONDecoderConfiguration,
        ) throws -> Output,
        inferredAccept: String?,
    ) {
        decodeValue = jsonDecode
        self.inferredAccept = inferredAccept
    }

    package func decode(
        _ data: Data,
        response: HTTPResponse,
        clientJSONDecoderConfiguration: JSONDecoderConfiguration,
        endpointJSONDecoderConfiguration: JSONDecoderConfiguration,
    ) throws -> Output {
        try decodeValue(
            data,
            response,
            clientJSONDecoderConfiguration,
            endpointJSONDecoderConfiguration,
        )
    }

    package func decode(_ data: Data, response: HTTPResponse) throws -> Output {
        try decode(
            data,
            response: response,
            clientJSONDecoderConfiguration: { _ in },
            endpointJSONDecoderConfiguration: { _ in },
        )
    }
}

extension ResponseDecoding where Output == Data {
    /// Returns the response bytes unchanged.
    public static var data: Self {
        Self { data, _ in data }
    }
}

extension ResponseDecoding where Output: Decodable {
    /// Decodes a JSON response using a fresh configured decoder for every execution.
    ///
    /// The strategy infers `Accept: application/json` but does not inspect the response's
    /// `Content-Type` field before decoding.
    ///
    /// - Returns: A JSON response decoding strategy.
    public static func json() -> Self {
        Self(
            jsonDecode: { data, _, clientConfiguration, endpointConfiguration in
                let decoder = JSONDecoder()
                clientConfiguration(decoder)
                endpointConfiguration(decoder)
                return try decoder.decode(Output.self, from: data)
            },
            inferredAccept: "application/json",
        )
    }
}

extension ResponseDecoding {
    /// Decodes a response with a synchronous Sendable closure.
    ///
    /// The closure receives both the unmodified response bytes and HTTP metadata. Errors thrown
    /// by the closure propagate unchanged.
    ///
    /// - Parameter decode: The synchronous response decoder.
    /// - Returns: A response decoding strategy backed by the supplied closure.
    public static func custom(
        decode: @escaping @Sendable (Data, HTTPResponse) throws -> Output,
    ) -> Self {
        Self(decode: decode)
    }
}

/// Selects how an empty response value handles response bytes.
public enum EmptyResponseBodyPolicy: Sendable, Equatable {
    /// Produces an empty response value without inspecting response bytes.
    case ignore

    /// Produces an empty response value only when the response contains no bytes.
    case requireEmpty
}

/// Represents a response whose decoded value carries no data.
public struct EmptyResponse: Sendable, Equatable, Hashable, Codable {
    /// Creates an empty response value.
    public init() {}
}

extension ResponseDecoding where Output == EmptyResponse {
    /// Creates an empty response strategy with an explicit body policy.
    ///
    /// - Parameter policy: Whether response bytes are ignored or must be empty. Defaults to
    ///   ignoring response bytes.
    /// - Returns: An empty response decoding strategy.
    public static func empty(policy: EmptyResponseBodyPolicy = .ignore) -> Self {
        Self { data, _ in
            if policy == .requireEmpty, !data.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Expected an empty response body but received \(data.count) bytes.",
                    ),
                )
            }
            return EmptyResponse()
        }
    }
}
