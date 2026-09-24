//
//  Endpoint.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// A reusable HTTP contract that defines an operation's method, route, query, headers, and response decoding.
public struct Endpoint<Input: Sendable, Body: Sendable, Output: Sendable>: Sendable {
    private enum HeaderStorage: Sendable {
        case fixed(HTTPFields)
        case inputDerived(@Sendable (Input) -> HTTPFields)
    }

    package let method: HTTPRequest.Method
    package let route: EndpointRoute<Input>
    package let query: QueryEncoding<Input>
    package let response: ResponseDecoding<Output>
    private let headerStorage: HeaderStorage

    private init(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        query: QueryEncoding<Input>,
        response: ResponseDecoding<Output>,
        headerStorage: HeaderStorage = .fixed(HTTPFields()),
    ) {
        self.method = method
        self.route = route
        self.query = query
        self.response = response
        self.headerStorage = headerStorage
    }

    private func replacingHeaderStorage(_ headerStorage: HeaderStorage) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            response: response,
            headerStorage: headerStorage,
        )
    }

    package func resolveHeaders(input: Input) -> HTTPFields {
        switch headerStorage {
        case let .fixed(fields):
            fields
        case let .inputDerived(makeHeaders):
            makeHeaders(input)
        }
    }

    package var constantHeaders: HTTPFields {
        switch headerStorage {
        case let .fixed(fields):
            fields
        case .inputDerived:
            HTTPFields()
        }
    }

    /// Returns a copy that replaces the endpoint's complete header configuration.
    ///
    /// - Parameter fields: The fixed endpoint-owned HTTP fields.
    /// - Returns: An endpoint copy using the supplied fields for every request.
    public func headers(_ fields: HTTPFields) -> Self {
        replacingHeaderStorage(.fixed(fields))
    }

    /// Returns a copy whose endpoint-owned HTTP fields are derived from request input.
    ///
    /// The builder runs once when a Request binds input. A no-input Request does not invoke this
    /// builder and uses an empty endpoint header layer.
    ///
    /// - Parameter makeHeaders: A nonthrowing, Sendable builder for endpoint-owned fields.
    /// - Returns: An endpoint copy using the supplied input-derived header configuration.
    public func headers(
        _ makeHeaders: @escaping @Sendable (Input) -> HTTPFields,
    ) -> Self {
        replacingHeaderStorage(.inputDerived(makeHeaders))
    }

    /// Returns a copy with one endpoint field set or replaced.
    ///
    /// Existing values for `name` in this endpoint layer are replaced. Other field names are
    /// preserved, including when this endpoint uses an input-derived header builder.
    ///
    /// - Parameters:
    ///   - name: The HTTP field name to set.
    ///   - value: The replacement value.
    /// - Returns: An endpoint copy with the field-level override applied.
    public func header(_ name: HTTPField.Name, _ value: String) -> Self {
        switch headerStorage {
        case var .fixed(fields):
            fields[fields: name] = [HTTPField(name: name, value: value)]
            return replacingHeaderStorage(.fixed(fields))
        case let .inputDerived(makeHeaders):
            return replacingHeaderStorage(.inputDerived { input in
                var fields = makeHeaders(input)
                fields[fields: name] = [HTTPField(name: name, value: value)]
                return fields
            })
        }
    }
}

package enum ResolvedEndpointRoute: Sendable {
    case absolute(URL)
    case relative([String])
}

/// An endpoint-owned route that resolves to an absolute URL or structured path for an invocation.
public struct EndpointRoute<Input: Sendable>: Sendable {
    private enum Storage: Sendable {
        case absolute(URL)
        case inputDerivedAbsolute(@Sendable (Input) -> URL)
        case inputDerivedRelative(@Sendable (Input) -> [String])
    }

    private let storage: Storage
    private let noInputRoute: ResolvedEndpointRoute

    package func resolve(input: Input) -> ResolvedEndpointRoute {
        switch storage {
        case let .absolute(url):
            .absolute(url)
        case let .inputDerivedAbsolute(makeURL):
            .absolute(makeURL(input))
        case let .inputDerivedRelative(makePath):
            .relative(makePath(input))
        }
    }

    package var constantRoute: ResolvedEndpointRoute {
        noInputRoute
    }
}

extension EndpointRoute {
    /// Creates an absolute route by deriving its URL from endpoint input.
    ///
    /// - Parameters:
    ///   - inputWitness: A value proving that the input type has an inhabitant. The value is not
    ///     retained or used to resolve an invocation.
    ///   - makeURL: A nonthrowing builder that returns the route for one invocation.
    /// - Returns: A route that resolves the supplied input to an absolute URL.
    public static func absolute(
        forInput inputWitness: Input,
        makeURL: @escaping @Sendable (Input) -> URL,
    ) -> Self {
        _ = inputWitness
        // Input-bearing requests resolve through the builder; this slot is never used by them.
        return Self(
            storage: .inputDerivedAbsolute(makeURL),
            noInputRoute: .absolute(URL(fileURLWithPath: "/")),
        )
    }

    /// Creates a relative route from input-derived path components.
    ///
    /// Each returned component represents one path segment and is encoded independently when the
    /// request executes.
    ///
    /// - Parameters:
    ///   - inputWitness: A value proving that the input type has an inhabitant. The value is not
    ///     retained or used to resolve an invocation.
    ///   - makePath: A nonthrowing builder that returns structured path components for the input.
    /// - Returns: A route that resolves the supplied input to structured path components.
    public static func relative(
        forInput inputWitness: Input,
        makePath: @escaping @Sendable (Input) -> [String],
    ) -> Self {
        _ = inputWitness
        // Input-bearing requests resolve through the builder; this slot is never used by them.
        return Self(
            storage: .inputDerivedRelative(makePath),
            noInputRoute: .absolute(URL(fileURLWithPath: "/")),
        )
    }
}

extension EndpointRoute where Input == Never {
    /// Creates a no-input route from a fixed absolute URL.
    ///
    /// - Parameter url: The absolute URL used by every invocation.
    /// - Returns: A route that does not require endpoint input.
    public static func absolute(_ url: URL) -> Self {
        Self(storage: .absolute(url), noInputRoute: .absolute(url))
    }
}

extension Endpoint where Body == Never {
    /// Creates a bodyless endpoint that decodes the response using the supplied strategy.
    ///
    /// - Parameters:
    ///   - method: The explicit HTTP method for every invocation.
    ///   - route: The endpoint-owned route.
    ///   - response: The response decoding strategy.
    ///   - query: The endpoint-owned query mechanism, defaulting to no endpoint query values.
    /// - Returns: An immutable data endpoint.
    public static func data(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        response: ResponseDecoding<Output>,
        query: QueryEncoding<Input> = .none,
    ) -> Self {
        Self(method: method, route: route, query: query, response: response)
    }
}
