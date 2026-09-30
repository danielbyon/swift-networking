//
//  RequestMatcher.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import CoreFoundation
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
    public static func url(_ expected: URL) -> Self {
        let expectedShape = URLShape(url: expected)
        return Self { request in
            guard let actualShape = URLShape(request: request.httpRequest),
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
        let expectedValue = try JSONSemanticValue.decode(expected)
        return Self { request in
            guard let data = try? request.readBodyBytes(),
                  let actualValue = try? JSONSemanticValue.decode(data),
                  actualValue == expectedValue
            else {
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

private enum JSONSemanticValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONSemanticValue])
    case object([String: JSONSemanticValue])

    static func decode(_ data: Data) throws -> Self {
        do {
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let result = makeValue(value) else {
                throw RequestMatcherError.invalidJSON
            }

            return result
        } catch {
            throw RequestMatcherError.invalidJSON
        }
    }

    private static func makeValue(_ value: Any) -> Self? {
        if value is NSNull {
            return .null
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            guard let exactNumber = JSONNumber(number.stringValue) else {
                return nil
            }

            return .number(exactNumber)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let values = value as? [Any] {
            let decoded = values.compactMap(makeValue)
            return decoded.count == values.count ? .array(decoded) : nil
        }
        if let values = value as? [String: Any] {
            var decoded: [String: Self] = [:]
            for (key, value) in values {
                guard let value = makeValue(value) else {
                    return nil
                }

                decoded[key] = value
            }
            return .object(decoded)
        }
        return nil
    }
}

private struct JSONNumber: Sendable, Equatable {
    let isNegative: Bool
    let digits: String
    let exponent: Int

    init?(_ source: String) {
        var value = source[...]
        let isNegative = value.first == "-"
        if isNegative {
            value = value.dropFirst()
        }

        let exponentParts = value.split(maxSplits: 1, whereSeparator: { $0 == "e" || $0 == "E" })
        guard let significand = exponentParts.first else {
            return nil
        }

        let explicitExponent: Int
        if exponentParts.count == 2 {
            guard let parsedExponent = Int(exponentParts[1]) else {
                return nil
            }

            explicitExponent = parsedExponent
        } else {
            explicitExponent = 0
        }

        let decimalParts = significand.split(separator: ".", omittingEmptySubsequences: false)
        guard decimalParts.count <= 2 else {
            return nil
        }

        let fraction = decimalParts.count == 2 ? String(decimalParts[1]) : ""
        var digits = decimalParts.map(String.init).joined()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return nil
        }

        var normalizedExponent = explicitExponent - fraction.count
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
        }
        if digits.allSatisfy({ $0 == "0" }) {
            self.isNegative = false
            self.digits = "0"
            exponent = 0
            return
        }
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
            normalizedExponent += 1
        }

        self.isNegative = isNegative
        self.digits = digits
        exponent = normalizedExponent
    }
}
