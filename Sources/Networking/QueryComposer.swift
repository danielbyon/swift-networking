//
//  QueryComposer.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

package enum QueryRouteKind: Sendable {
    case absolute
    case relative
}

package enum QueryComposer {
    package static func compose(
        url: URL,
        routeKind: QueryRouteKind,
        clientQueryItems: [URLQueryItem],
        clientEncoderConfiguration: URLQueryEncoder.Configuration,
        endpointQuery: CapturedQuery,
        requestQueryItems: [URLQueryItem],
        requestID: RequestID,
    ) throws -> URL {
        let endpointConfiguration: URLQueryEncoder.Configuration =
            switch endpointQuery {
            case let .codable(_, configuration):
                configuration
            case .none,
                 .items:
                .init()
            }

        let encoder = URLQueryEncoder(
            configuration: clientEncoderConfiguration.applying(endpointConfiguration),
        )
        let endpointItems: [URLQueryItem]
        switch endpointQuery {
        case .none:
            endpointItems = []
        case let .items(items):
            endpointItems = items
        case let .codable(encode, _):
            do {
                endpointItems = try encode(encoder)
            } catch let error as URLQueryEncodingError {
                throw RequestConstructionError(requestID: requestID, reason: .urlQueryEncoding(error))
            } catch {
                throw RequestConstructionError(requestID: requestID, reason: .queryCompositionFailed)
            }
        }

        var values: [ComposedQueryItem] =
            if routeKind == .absolute {
                try rawItems(from: url, requestID: requestID)
            } else {
                try clientQueryItems.map {
                    try ComposedQueryItem.generated($0, requestID: requestID)
                }
            }

        try appendLayer(endpointItems, to: &values, requestID: requestID)
        try appendLayer(requestQueryItems, to: &values, requestID: requestID)

        let hasEmbeddedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery != nil
        guard !values.isEmpty || hasEmbeddedQuery else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RequestConstructionError(requestID: requestID, reason: .queryCompositionFailed)
        }

        components.percentEncodedQuery = values.map(\.percentEncodedValue).joined(separator: "&")
        guard let composedURL = components.url else {
            throw RequestConstructionError(requestID: requestID, reason: .queryCompositionFailed)
        }

        return composedURL
    }

    private static func appendLayer(
        _ items: [URLQueryItem],
        to values: inout [ComposedQueryItem],
        requestID: RequestID,
    ) throws {
        guard !items.isEmpty else {
            return
        }

        let keys = Set(items.map(\.name))
        values.removeAll { keys.contains($0.semanticKey) }
        let generatedItems = try items.map {
            try ComposedQueryItem.generated($0, requestID: requestID)
        }
        values.append(contentsOf: generatedItems)
    }

    private static func rawItems(from url: URL, requestID: RequestID) throws -> [ComposedQueryItem] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery
        else {
            return []
        }

        return try query.split(separator: "&", omittingEmptySubsequences: false).map { segment in
            let rawSegment = String(segment)
            let rawKey =
                if let first = rawSegment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first {
                    String(first)
                } else {
                    ""
                }
            guard let semanticKey = rawKey.removingPercentEncoding else {
                throw RequestConstructionError(requestID: requestID, reason: .queryCompositionFailed)
            }

            return .raw(semanticKey: semanticKey, value: rawSegment)
        }
    }

    private struct ComposedQueryItem {
        let semanticKey: String
        let percentEncodedValue: String

        static func raw(semanticKey: String, value: String) -> Self {
            Self(semanticKey: semanticKey, percentEncodedValue: value)
        }

        static func generated(_ item: URLQueryItem, requestID: RequestID) throws -> Self {
            var components = URLComponents()
            components.queryItems = [item]
            guard let query = components.percentEncodedQuery else {
                throw RequestConstructionError(requestID: requestID, reason: .queryCompositionFailed)
            }

            return Self(semanticKey: item.name, percentEncodedValue: query)
        }
    }
}
