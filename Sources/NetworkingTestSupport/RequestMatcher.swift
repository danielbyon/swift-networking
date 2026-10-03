//
//  RequestMatcher.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking

/// Selects whether a collection matcher requires an exact collection or a subset.
public enum RequestMatchSemantics: Sendable, Equatable {
    /// Requires exactly the requested values under the collection's documented comparison rules.
    case exact

    /// Requires each requested value while allowing additional values in the request.
    case subset
}

/// Describes why one request matcher did not match a recorded transport attempt.
public enum RequestMismatchReason: Sendable, Equatable {
    /// The request method differed.
    case method

    /// The complete URL differed.
    case url

    /// The URL path differed.
    case path

    /// The URL query did not satisfy the selected exact or subset semantics.
    case query

    /// The request headers did not satisfy the selected exact or subset semantics.
    case headers

    /// The request body bytes differed or could not be read.
    case body

    /// The request body was not semantically equal to the expected JSON value.
    case semanticJSONBody

    /// The selected typed request-context value differed or was absent.
    case requestContext

    /// The transport attempt number differed.
    case attemptNumber

    /// A custom matcher returned false.
    case customMatcher

    /// The mismatch reasons from child matchers that failed an `and` composition, in child order.
    /// The composition fails when at least one child fails.
    case allOf([RequestMismatchReason])

    /// Every matcher in an `or` composition failed, with each child reason in order.
    case anyOf([RequestMismatchReason])

    /// A matcher wrapped in `not` matched when it was expected not to.
    case negatedMatcherMatched
}

/// An error raised while constructing a semantic JSON matcher.
public enum RequestMatcherError: Error, Sendable, Equatable {
    /// The expected bytes do not contain one valid JSON value.
    case invalidJSON
}

/// A Sendable predicate over a request after request adapters and authentication have run.
///
/// Built-in matchers report structured mismatch reasons. Custom matchers report a generic reason
/// and should avoid side effects because explicit request-order verification evaluates them again.
public struct RequestMatcher: Sendable {
    private let evaluate: @Sendable (RecordedRequest) -> RequestMismatchReason?

    /// Matches the transport-ready HTTP method.
    public static func method(_ expected: HTTPRequest.Method) -> Self {
        Self { request in
            request.httpRequest.method == expected ? nil : .method
        }
    }

    /// Matches scheme, authority, path, and the encoded query of a complete URL.
    ///
    /// The transport-ready request must contain its own scheme and authority.
    public static func url(_ expected: URL) -> Self {
        let expectedShape = URLShape(url: expected)
        return Self { request in
            guard request.httpRequest.scheme != nil,
                  request.httpRequest.authority != nil,
                  let actualShape = URLShape(request: request.httpRequest),
                  actualShape == expectedShape
            else {
                return .url
            }

            return nil
        }
    }

    /// Matches the encoded URL path without considering its query.
    ///
    /// Supply a path string such as `/items/42`; percent-encoded characters are compared as encoded.
    public static func path(_ expected: String) -> Self {
        let expectedPath = URLComponents(string: expected)?.percentEncodedPath ?? expected
        return Self { request in
            guard let path = URLShape(request: request.httpRequest)?.path,
                  path == expectedPath
            else {
                return .path
            }

            return nil
        }
    }

    /// Matches URL query items using explicit exact or subset semantics.
    ///
    /// Exact matching compares ordered name/value pairs, including duplicates. Subset matching
    /// requires each requested pair, including duplicate occurrences, while ignoring order and
    /// allowing additional query items.
    public static func query(
        _ expected: [URLQueryItem],
        semantics: RequestMatchSemantics,
    ) -> Self {
        let expectedItems = expected.map(QueryItem.init)
        return Self { request in
            let actualItems = URLShape(request: request.httpRequest)?.queryItems
            guard let actualItems,
                  collectionMatches(actualItems, expectedItems, semantics: semantics)
            else {
                return .query
            }

            return nil
        }
    }

    /// Matches HTTP fields using explicit exact or subset semantics.
    ///
    /// Field names are compared case-insensitively. Exact matching requires the same fields and
    /// repeated values, regardless of iteration order. Subset matching requires every requested
    /// field/value occurrence while allowing additional fields and values.
    public static func headers(
        _ expected: HTTPFields,
        semantics: RequestMatchSemantics,
    ) -> Self {
        let expectedFields = expected.map(HeaderValue.init).sorted(by: headerValuePrecedes)
        return Self { request in
            let actualFields = request.httpRequest.headerFields.map(HeaderValue.init).sorted(by: headerValuePrecedes)
            guard collectionMatches(actualFields, expectedFields, semantics: semantics) else {
                return .headers
            }

            return nil
        }
    }

    /// Matches the prepared request body byte-for-byte.
    ///
    /// Using this matcher opts into reading a file-backed body during matching. Ordinary recording
    /// retains only the file URL and never reads file contents.
    public static func body(_ expected: Data) -> Self {
        Self { request in
            guard let actual = try? request.readBodyBytes(), actual == expected else {
                return .body
            }

            return nil
        }
    }

    /// Matches a JSON request body by decoded JSON value rather than source formatting.
    ///
    /// Object key order and numeric spelling do not affect equality. Array order is significant,
    /// and numbers are compared exactly without a floating-point tolerance.
    public static func jsonBody(_ expected: Data) throws -> Self {
        let matchesJSON = try JSONSemanticMatcher.predicate(expected: expected)
        return Self { request in
            guard let data = try? request.readBodyBytes(), matchesJSON(data) else {
                return .semanticJSONBody
            }

            return nil
        }
    }

    /// Matches one typed value stored in the request context. The key type itself need not conform to `Sendable`.
    public static func requestContext<Key: RequestContextKey>(
        _ key: Key.Type,
        equals expected: Key.Value,
    ) -> Self where Key.Value: Equatable {
        let keyIdentifier = ObjectIdentifier(key)
        return Self { request in
            request.requestContext.matches(expected, forKeyIdentifier: keyIdentifier) ? nil : .requestContext
        }
    }

    /// Matches the one-based transport attempt number.
    public static func attemptNumber(_ expected: UInt) -> Self {
        Self { request in
            request.attemptNumber == expected ? nil : .attemptNumber
        }
    }

    /// Matches through a caller-supplied Sendable predicate.
    public static func custom(
        _ predicate: @escaping @Sendable (RecordedRequest) -> Bool,
    ) -> Self {
        Self { predicate($0) ? nil : .customMatcher }
    }

    /// Requires both matchers to match.
    public func and(_ other: Self) -> Self {
        Self { request in
            let reasons = [evaluate(request), other.evaluate(request)].compactMap(\.self)
            return reasons.isEmpty ? nil : .allOf(reasons)
        }
    }

    /// Requires either matcher to match.
    public func or(_ other: Self) -> Self {
        Self { request in
            let left = evaluate(request)
            let right = other.evaluate(request)
            switch (left, right) {
            case (nil, _),
                 (_, nil):
                return nil
            case let (left?, right?):
                return .anyOf([left, right])
            }
        }
    }

    /// Matches when this matcher does not match.
    public func not() -> Self {
        Self { request in
            evaluate(request) == nil ? .negatedMatcherMatched : nil
        }
    }

    package func mismatch(for request: RecordedRequest) -> RequestMismatchReason? {
        evaluate(request)
    }
}

extension RequestMatcher {
    /// Wraps an already-validated semantic JSON predicate as a request-body matcher.
    ///
    /// Callers obtain the predicate from `JSONSemanticMatcher` so every JSON convenience in
    /// TestSupport shares one decoded-equality model instead of introducing a parallel comparison.
    static func semanticJSONBody(_ predicate: @escaping @Sendable (Data) -> Bool) -> Self {
        Self { request in
            guard let body = try? request.readBodyBytes(), predicate(body) else {
                return .semanticJSONBody
            }

            return nil
        }
    }
}

private struct QueryItem: Sendable, Equatable {
    let name: String
    let value: String?

    init(_ item: URLQueryItem) {
        name = item.name
        value = item.value
    }
}

private struct HeaderValue: Sendable, Equatable {
    let name: String
    let value: String

    init(_ field: HTTPField) {
        name = field.name.canonicalName.lowercased()
        value = field.value
    }
}

private struct URLShape: Sendable, Equatable {
    let scheme: String?
    let authority: String?
    let path: String
    let query: String?

    var queryItems: [QueryItem] {
        guard let query else {
            return []
        }

        let components = URLComponents(string: "https://matcher.invalid/?\(query)")
        return components?.queryItems?.map(QueryItem.init) ?? []
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        scheme = components.scheme?.lowercased()
        authority = Self.authority(host: components.host, port: components.port)
        path = components.percentEncodedPath
        query = components.percentEncodedQuery
    }

    init?(request: HTTPRequest) {
        guard let rawPath = request.path,
              let components = URLComponents(
                  string: "\(request.scheme ?? "https")://\(request.authority ?? "matcher.invalid")\(rawPath)",
              )
        else {
            return nil
        }

        scheme = components.scheme?.lowercased()
        authority = Self.authority(host: components.host, port: components.port)
        path = components.percentEncodedPath
        query = components.percentEncodedQuery
    }

    private static func authority(host: String?, port: Int?) -> String? {
        guard let host else {
            return nil
        }

        return port.map { "\(host.lowercased()):\($0)" } ?? host.lowercased()
    }
}

private func collectionMatches<Element: Equatable & Sendable>(
    _ actual: [Element],
    _ expected: [Element],
    semantics: RequestMatchSemantics,
) -> Bool {
    switch semantics {
    case .exact:
        return actual == expected
    case .subset:
        var unmatched = actual
        for expectedValue in expected {
            guard let index = unmatched.firstIndex(of: expectedValue) else {
                return false
            }

            unmatched.remove(at: index)
        }
        return true
    }
}

private func headerValuePrecedes(_ left: HeaderValue, _ right: HeaderValue) -> Bool {
    left.name == right.name ? left.value < right.value : left.name < right.name
}
