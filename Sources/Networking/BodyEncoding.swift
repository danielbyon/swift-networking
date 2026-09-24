//
//  BodyEncoding.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

package typealias JSONEncoderConfiguration = @Sendable (JSONEncoder) -> Void
package typealias JSONDecoderConfiguration = @Sendable (JSONDecoder) -> Void

/// Describes how an immutable request body becomes transport-ready data or file metadata.
public struct BodyEncoding<Body: Sendable>: Sendable {
    private let prepareValue: (@Sendable (
        Body,
        JSONEncoderConfiguration,
        JSONEncoderConfiguration,
    ) throws -> PreparedBody)?

    private init(
        prepare: @escaping @Sendable (
            Body,
            JSONEncoderConfiguration,
            JSONEncoderConfiguration,
        ) throws -> PreparedBody,
    ) {
        prepareValue = prepare
    }

    private init(bodyless: Void) {
        _ = bodyless
        prepareValue = nil
    }

    package func prepare(
        _ body: Body,
        clientJSONEncoderConfiguration: JSONEncoderConfiguration,
        endpointJSONEncoderConfiguration: JSONEncoderConfiguration,
    ) throws -> PreparedBody {
        guard let prepareValue else {
            return .none
        }

        return try prepareValue(body, clientJSONEncoderConfiguration, endpointJSONEncoderConfiguration)
    }
}

extension BodyEncoding where Body: Encodable {
    /// Encodes the body as JSON using a fresh configured encoder for each execution.
    ///
    /// - Parameter contentType: The inferred media type, defaulting to `application/json`.
    /// - Returns: A replayable JSON body encoding strategy.
    public static func json(contentType: String? = nil) -> Self {
        Self { body, clientConfiguration, endpointConfiguration in
            let encoder = JSONEncoder()
            clientConfiguration(encoder)
            endpointConfiguration(encoder)
            let data = try encoder.encode(body)
            return .data(data, contentType: contentType ?? "application/json")
        }
    }
}

extension BodyEncoding where Body == Data {
    /// Uses the supplied bytes unchanged.
    ///
    /// - Parameter contentType: An optional media type inferred for the request.
    /// - Returns: A body encoding strategy that retains the original byte sequence.
    public static func data(contentType: String? = nil) -> Self {
        Self { data, _, _ in .data(data, contentType: contentType) }
    }
}

extension BodyEncoding where Body == URL {
    /// Retains a file URL and optional media type without reading the file.
    ///
    /// If the selected operation cannot safely execute the file-backed body representation,
    /// request construction fails before transport.
    ///
    /// - Parameter contentType: An optional media type inferred for the request.
    /// - Returns: A body encoding strategy that retains the URL as file metadata.
    public static func file(contentType: String? = nil) -> Self {
        Self { url, _, _ in .file(url, contentType: contentType) }
    }
}

extension BodyEncoding {
    /// Encodes the body through a synchronous replayable in-memory encoder.
    ///
    /// The supplied closure runs during each execution. Its thrown errors propagate unchanged.
    ///
    /// - Parameter encode: A Sendable closure that converts the body into bytes.
    /// - Returns: A body encoding strategy backed by the supplied closure.
    public static func custom(
        encode: @escaping @Sendable (Body) throws -> Data,
    ) -> Self {
        Self { body, _, _ in try .data(encode(body), contentType: nil) }
    }
}

extension BodyEncoding where Body == Never {
    package static var bodyless: Self {
        Self(bodyless: ())
    }
}

/// A read-only view of the body prepared for a pending transport attempt.
public enum PreparedRequestBody: Sendable {
    /// The request has no body.
    case none
    /// The request body is available as in-memory bytes.
    case data(Data)
    /// The request body is retained as a file URL.
    case file(URL)
}

package enum PreparedBody: Sendable {
    case none
    case data(Data, contentType: String?)
    case file(URL, contentType: String?)

    package var contentType: String? {
        switch self {
        case .none:
            nil
        case let .data(_, contentType),
             let .file(_, contentType):
            contentType
        }
    }

    package var inferredHeaders: HTTPFields {
        var fields = HTTPFields()
        if let contentType {
            fields[fields: .contentType] = [HTTPField(name: .contentType, value: contentType)]
        }
        return fields
    }

    package var inspection: PreparedRequestBody {
        switch self {
        case .none:
            .none
        case let .data(data, _):
            .data(data)
        case let .file(url, _):
            .file(url)
        }
    }
}

package struct RequestBody: Sendable {
    private let prepareValue: @Sendable (
        JSONEncoderConfiguration,
        JSONEncoderConfiguration,
    ) throws -> PreparedBody

    package init<Body: Sendable>(body: Body, encoding: BodyEncoding<Body>) {
        prepareValue = { clientConfiguration, endpointConfiguration in
            try encoding.prepare(
                body,
                clientJSONEncoderConfiguration: clientConfiguration,
                endpointJSONEncoderConfiguration: endpointConfiguration,
            )
        }
    }

    package func prepare(
        clientJSONEncoderConfiguration: JSONEncoderConfiguration,
        endpointJSONEncoderConfiguration: JSONEncoderConfiguration,
    ) throws -> PreparedBody {
        try prepareValue(clientJSONEncoderConfiguration, endpointJSONEncoderConfiguration)
    }
}
