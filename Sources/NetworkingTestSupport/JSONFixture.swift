//
//  JSONFixture.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Immutable, validated JSON content that tests can match, decode, and snapshot deterministically.
///
/// Create a fixture from inline JSON text or bytes, from an explicit bundle resource, or by
/// encoding a model. Every construction path validates the content with the same semantic parser
/// that `RequestMatcher.jsonBody(_:)` uses, so a fixture always holds syntactically valid JSON,
/// comparisons ignore object key order, arrays keep their order, and decoded numbers compare
/// exactly without floating-point tolerance.
///
/// Bundle loading never guesses a bundle: the caller always supplies the `Bundle` to read from.
public struct JSONFixture: Sendable {
    /// Errors raised while loading or preparing a fixture.
    public enum LoadingError: Error, LocalizedError, Sendable, Equatable {
        /// The supplied bundle did not contain the named resource.
        case resourceNotFound(resource: String, subdirectory: String?, bundlePath: String)

        /// The bundle contained the resource, but its contents could not be read.
        case unreadableResource(resource: String, subdirectory: String?, bundlePath: String)

        /// Validated content could not be rendered as canonical JSON.
        case canonicalizationFailed(reason: String)

        /// A human-readable description that names the resource and the bundle that was searched.
        public var errorDescription: String? {
            switch self {
            case let .resourceNotFound(resource, subdirectory, bundlePath):
                "JSON fixture resource '\(resource)' was not found in "
                    + Self.locationDescription(subdirectory: subdirectory, bundlePath: bundlePath) + "."
            case let .unreadableResource(resource, subdirectory, bundlePath):
                "JSON fixture resource '\(resource)' could not be read from "
                    + Self.locationDescription(subdirectory: subdirectory, bundlePath: bundlePath) + "."
            case let .canonicalizationFailed(reason):
                "JSON fixture content could not be rendered as canonical JSON: \(reason)."
            }
        }

        private static func locationDescription(subdirectory: String?, bundlePath: String) -> String {
            guard let subdirectory, !subdirectory.isEmpty else {
                return "bundle at '\(bundlePath)'"
            }

            return "bundle at '\(bundlePath)', subdirectory '\(subdirectory)',"
        }
    }

    /// The original validated JSON bytes exactly as they were supplied.
    public let data: Data

    /// The canonical pretty-printed rendering used by the `.json` snapshot strategy.
    let canonicalJSON: String

    /// The semantic equality predicate shared with `RequestMatcher.jsonBody(_:)`.
    private let bodyPredicate: @Sendable (Data) -> Bool

    /// Creates a fixture from inline JSON text.
    ///
    /// - Throws: `RequestMatcherError.invalidJSON` when the text is not exactly one valid JSON value.
    public init(json: String) throws {
        try self.init(data: Data(json.utf8))
    }

    /// Creates a fixture from inline JSON bytes.
    ///
    /// - Throws: `RequestMatcherError.invalidJSON` when the bytes are not exactly one valid JSON value.
    public init(data: Data) throws {
        bodyPredicate = try JSONSemanticMatcher.predicate(expected: data)
        let canonicalData = try JSONCanonicalization.canonicalData(from: data)
        self.data = data
        canonicalJSON = String(decoding: canonicalData, as: UTF8.self)
    }

    /// Creates a fixture by encoding a model with a caller-configurable encoder.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - configure: A closure that configures the encoder before it encodes `value`.
    /// - Throws: An encoding error, or `RequestMatcherError.invalidJSON` when the encoded bytes are
    ///   not valid JSON, which cannot happen for a well-behaved `Encodable` conformance.
    public init(encoding value: some Encodable, configure: (JSONEncoder) -> Void = { _ in }) throws {
        let encoder = JSONEncoder()
        configure(encoder)
        try self.init(data: encoder.encode(value))
    }

    /// Loads a fixture from an explicit bundle resource.
    ///
    /// When `name` has no extension, the resource is searched with a `.json` extension.
    /// An explicitly supplied extension is used as written.
    ///
    /// The resource name may include its file extension, such as `login-success.json`. Loading
    /// never consults `Bundle.main`, a caller test bundle, or `Bundle.module`; the supplied bundle
    /// is the only bundle searched, and it appears in every failure diagnostic.
    ///
    /// - Parameters:
    ///   - name: The resource file name, with or without its extension.
    ///   - bundle: The bundle that owns the resource.
    ///   - subdirectory: An optional subdirectory inside the bundle.
    /// - Throws: `LoadingError.resourceNotFound` when the bundle has no such resource,
    ///   `LoadingError.unreadableResource` when its contents cannot be read, or
    ///   `RequestMatcherError.invalidJSON` when its contents are not valid JSON.
    public static func resource(
        named name: String,
        in bundle: Bundle,
        subdirectory: String? = nil,
    ) throws -> JSONFixture {
        let parts = splitResourceName(name)
        guard let url = bundle.url(
            forResource: parts.base,
            withExtension: parts.fileExtension ?? "json",
            subdirectory: subdirectory,
        ) else {
            throw LoadingError.resourceNotFound(
                resource: name,
                subdirectory: subdirectory,
                bundlePath: bundle.bundlePath,
            )
        }

        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            throw LoadingError.unreadableResource(
                resource: name,
                subdirectory: subdirectory,
                bundlePath: bundle.bundlePath,
            )
        }

        return try JSONFixture(data: contents)
    }

    /// Decodes the fixture into a model with a caller-configurable decoder.
    ///
    /// - Parameters:
    ///   - type: The model type to decode.
    ///   - configure: A closure that configures the decoder before it decodes the fixture.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        configure: (JSONDecoder) -> Void = { _ in },
    ) throws -> Value {
        let decoder = JSONDecoder()
        configure(decoder)
        return try decoder.decode(type, from: data)
    }

    /// Returns a request matcher that compares request bodies with this fixture's semantics.
    ///
    /// The matcher reuses `RequestMatcher.jsonBody(_:)` behavior, so object key order is
    /// insignificant, array order is significant, and numbers compare exactly by decoded value.
    public func requestMatcher() -> RequestMatcher {
        RequestMatcher.semanticJSONBody(bodyPredicate)
    }

    /// Returns an in-memory HTTP stub response that delivers this fixture as JSON.
    ///
    /// The response defaults to `200 OK` and `Content-Type: application/json`. A caller-supplied
    /// `Content-Type` field overrides the default.
    public func httpStubResponse(
        status: HTTPResponse.Status = .ok,
        headers: HTTPFields = [:],
    ) -> StubResponse {
        .httpResponse(data: data, response: jsonHTTPResponse(status: status, headers: headers))
    }

    /// Returns a download stub response that delivers this fixture as JSON.
    ///
    /// The response defaults to `200 OK` and `Content-Type: application/json`. A caller-supplied
    /// `Content-Type` field overrides the default.
    public func downloadStubResponse(
        status: HTTPResponse.Status = .ok,
        headers: HTTPFields = [:],
    ) -> StubResponse {
        .download(data: data, response: jsonHTTPResponse(status: status, headers: headers))
    }

    private func jsonHTTPResponse(status: HTTPResponse.Status, headers: HTTPFields) -> HTTPResponse {
        var fields = headers
        if fields[.contentType] == nil {
            fields[.contentType] = "application/json"
        }

        return HTTPResponse(status: status, headerFields: fields)
    }

    private static func splitResourceName(_ name: String) -> (base: String, fileExtension: String?) {
        guard let separator = name.lastIndex(of: "."), separator != name.startIndex else {
            return (name, nil)
        }

        return (String(name[..<separator]), String(name[name.index(after: separator)...]))
    }
}
