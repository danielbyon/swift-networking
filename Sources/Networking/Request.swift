//
//  Request.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// An immutable invocation of an endpoint with its input and body dimensions erased.
public struct Request<Output: Sendable>: Sendable {
    package let method: HTTPRequest.Method
    package let route: ResolvedEndpointRoute
    package let query: CapturedQuery
    package let requestQueryItems: [URLQueryItem]
    package let response: ResponseDecoding<Output>

    private init(
        method: HTTPRequest.Method,
        route: ResolvedEndpointRoute,
        query: CapturedQuery,
        requestQueryItems: [URLQueryItem],
        response: ResponseDecoding<Output>,
    ) {
        self.method = method
        self.route = route
        self.query = query
        self.requestQueryItems = requestQueryItems
        self.response = response
    }

    /// Binds endpoint input to a bodyless endpoint and resolves its route.
    ///
    /// - Parameters:
    ///   - endpoint: The reusable endpoint contract.
    ///   - input: The value used to resolve the endpoint route.
    public init<Input: Sendable>(endpoint: Endpoint<Input, Never, Output>, input: Input) {
        self.init(
            method: endpoint.method,
            route: endpoint.route.resolve(input: input),
            query: endpoint.query.capture(input: input),
            requestQueryItems: [],
            response: endpoint.response,
        )
    }

    /// Binds a no-input endpoint to an invocation and resolves its fixed route.
    ///
    /// - Parameter endpoint: The reusable endpoint contract with a fixed absolute route.
    public init(endpoint: Endpoint<Never, Never, Output>) {
        self.init(
            method: endpoint.method,
            route: endpoint.route.constantRoute,
            query: endpoint.query.constant,
            requestQueryItems: [],
            response: endpoint.response,
        )
    }

    /// Returns a copy with invocation-specific query items in caller-supplied order.
    ///
    /// Items with a key matching a lower-precedence query layer replace all lower-layer values for
    /// that key. This modifier does not replace the complete endpoint or route query.
    ///
    /// - Parameter queryItems: The request-level query items.
    /// - Returns: An immutable request copy with the supplied query override.
    public func queryItems(_ queryItems: [URLQueryItem]) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            requestQueryItems: queryItems,
            response: response,
        )
    }
}
