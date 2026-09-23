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
    package let response: ResponseDecoding<Output>

    /// Binds endpoint input to a bodyless endpoint and resolves its route.
    ///
    /// - Parameters:
    ///   - endpoint: The reusable endpoint contract.
    ///   - input: The value used to resolve the endpoint route.
    public init<Input: Sendable>(endpoint: Endpoint<Input, Never, Output>, input: Input) {
        method = endpoint.method
        route = endpoint.route.resolve(input: input)
        response = endpoint.response
    }

    /// Binds a no-input endpoint to an invocation and resolves its fixed route.
    ///
    /// - Parameter endpoint: The reusable endpoint contract with a fixed absolute route.
    public init(endpoint: Endpoint<Never, Never, Output>) {
        method = endpoint.method
        route = endpoint.route.constantRoute
        response = endpoint.response
    }
}
