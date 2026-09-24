//
//  QueryEncoding.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

package enum CapturedQuery: Sendable {
    case none
    case items([URLQueryItem])
    case codable(
        encode: @Sendable (URLQueryEncoder) throws -> [URLQueryItem],
        configuration: URLQueryEncoder.Configuration,
    )
}

/// Selects the one query construction mechanism owned by an endpoint.
public struct QueryEncoding<Input: Sendable>: Sendable {
    private enum Storage: Sendable {
        case none
        case inputItems(@Sendable (Input) -> [URLQueryItem])
        case inputCodable(@Sendable (Input) -> CapturedQuery)
        case fixed(CapturedQuery)
    }

    private let storage: Storage

    /// An endpoint with no endpoint-owned query values.
    public static var none: Self {
        Self(storage: .none)
    }

    /// Creates an input-derived explicit query-item mechanism.
    ///
    /// The builder is invoked once when a Request binds endpoint input. For `Input == Never`, a
    /// no-input Request treats this mechanism as absent and never invokes the builder.
    ///
    /// - Parameter makeItems: A nonthrowing Sendable query-item builder.
    /// - Returns: An endpoint query mechanism backed by explicit query items.
    public static func items(
        _ makeItems: @escaping @Sendable (Input) -> [URLQueryItem],
    ) -> Self {
        Self(storage: .inputItems(makeItems))
    }

    /// Creates an input-derived Codable query mechanism.
    ///
    /// The selector is invoked once when a Request binds endpoint input. Serialization is deferred
    /// until logical-execution preflight, where the client and endpoint encoder configurations are
    /// combined. For `Input == Never`, a no-input Request treats this mechanism as absent and never
    /// invokes the selector.
    ///
    /// - Parameters:
    ///   - configuration: Encoder strategy adjustments for this Codable query.
    ///   - select: A nonthrowing Sendable selector for the Codable query value.
    /// - Returns: An endpoint query mechanism backed by a selected Codable value.
    public static func codable(
        configuration: URLQueryEncoder.Configuration = .init(),
        _ select: @escaping @Sendable (Input) -> some Encodable & Sendable,
    ) -> Self {
        Self(storage: .inputCodable { input in
            let value = select(input)
            return .codable(
                encode: { encoder in
                    try encoder.encode(value)
                },
                configuration: configuration,
            )
        })
    }
}

extension QueryEncoding where Input == Never {
    /// Creates a no-input endpoint query from fixed explicit query items.
    ///
    /// - Parameter items: The query items in caller-supplied order.
    /// - Returns: A fixed endpoint query mechanism.
    public static func items(_ items: [URLQueryItem]) -> Self {
        Self(storage: .fixed(.items(items)))
    }

    /// Creates a no-input endpoint query from a fixed Codable value.
    ///
    /// - Parameters:
    ///   - value: The Codable query value to serialize during preflight.
    ///   - configuration: Encoder strategy adjustments for this Codable query.
    /// - Returns: A fixed endpoint query mechanism.
    public static func codable(
        _ value: some Encodable & Sendable,
        configuration: URLQueryEncoder.Configuration = .init(),
    ) -> Self {
        Self(storage: .fixed(.codable(
            encode: { encoder in
                try encoder.encode(value)
            },
            configuration: configuration,
        )))
    }
}

extension QueryEncoding {
    /// Captures an input-bearing query for a Request constructed with endpoint input.
    package func capture(input: Input) -> CapturedQuery {
        switch storage {
        case .none:
            .none
        case let .inputItems(makeItems):
            .items(makeItems(input))
        case let .inputCodable(select):
            select(input)
        case let .fixed(query):
            query
        }
    }

    /// Returns only fixed query values. Input-bearing query builders are deliberately absent from
    /// no-input Requests, including when `Input == Never`.
    package var constant: CapturedQuery {
        switch storage {
        case .none,
             .inputItems,
             .inputCodable:
            .none
        case let .fixed(query):
            query
        }
    }
}
