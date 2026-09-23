//
//  Endpoint.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// A reusable HTTP contract that defines an operation's method, route, and response decoding.
public struct Endpoint<Input: Sendable, Body: Sendable, Output: Sendable>: Sendable {
    package let method: HTTPRequest.Method
    package let route: EndpointRoute<Input>
    package let response: ResponseDecoding<Output>

    private init(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        response: ResponseDecoding<Output>,
    ) {
        self.method = method
        self.route = route
        self.response = response
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
    /// - Returns: An immutable data endpoint.
    public static func data(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        response: ResponseDecoding<Output>,
    ) -> Self {
        Self(method: method, route: route, response: response)
    }
}
