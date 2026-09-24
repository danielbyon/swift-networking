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
    package let endpointHeaders: HTTPFields
    package let requestHeaders: HTTPFields
    package let body: RequestBody?
    package let jsonEncoderConfiguration: JSONEncoderConfiguration
    package let jsonDecoderConfiguration: JSONDecoderConfiguration

    private init(
        method: HTTPRequest.Method,
        route: ResolvedEndpointRoute,
        query: CapturedQuery,
        requestQueryItems: [URLQueryItem],
        response: ResponseDecoding<Output>,
        endpointHeaders: HTTPFields,
        requestHeaders: HTTPFields = HTTPFields(),
        body: RequestBody? = nil,
        jsonEncoderConfiguration: @escaping JSONEncoderConfiguration = { _ in },
        jsonDecoderConfiguration: @escaping JSONDecoderConfiguration = { _ in },
    ) {
        self.method = method
        self.route = route
        self.query = query
        self.requestQueryItems = requestQueryItems
        self.response = response
        self.endpointHeaders = endpointHeaders
        self.requestHeaders = requestHeaders
        self.body = body
        self.jsonEncoderConfiguration = jsonEncoderConfiguration
        self.jsonDecoderConfiguration = jsonDecoderConfiguration
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
            endpointHeaders: endpoint.resolveHeaders(input: input),
            jsonEncoderConfiguration: endpoint.jsonEncoderConfiguration,
            jsonDecoderConfiguration: endpoint.jsonDecoderConfiguration,
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
            endpointHeaders: endpoint.constantHeaders,
            jsonEncoderConfiguration: endpoint.jsonEncoderConfiguration,
            jsonDecoderConfiguration: endpoint.jsonDecoderConfiguration,
        )
    }

    /// Binds endpoint input and a body value to a bodyful endpoint invocation.
    ///
    /// The endpoint input is captured immediately, while body encoding remains deferred until
    /// each logical execution.
    ///
    /// - Parameters:
    ///   - endpoint: The reusable endpoint contract.
    ///   - input: The value used to resolve the endpoint route, query, and input-derived headers.
    ///   - body: The immutable body value retained for execution.
    public init<Input: Sendable, Body: Sendable>(
        endpoint: Endpoint<Input, Body, Output>,
        input: Input,
        body: Body,
    ) {
        self.init(
            method: endpoint.method,
            route: endpoint.route.resolve(input: input),
            query: endpoint.query.capture(input: input),
            requestQueryItems: [],
            response: endpoint.response,
            endpointHeaders: endpoint.resolveHeaders(input: input),
            body: RequestBody(body: body, encoding: endpoint.bodyEncoding),
            jsonEncoderConfiguration: endpoint.jsonEncoderConfiguration,
            jsonDecoderConfiguration: endpoint.jsonDecoderConfiguration,
        )
    }

    /// Binds a body value to a no-input endpoint using only its constant route and query state.
    ///
    /// Input-derived route, query, or header builders are not invoked for `Never` input.
    /// Body encoding remains deferred until each logical execution.
    ///
    /// - Parameters:
    ///   - endpoint: The reusable no-input endpoint contract.
    ///   - body: The immutable body value retained for execution.
    public init<Body: Sendable>(endpoint: Endpoint<Never, Body, Output>, body: Body) {
        self.init(
            method: endpoint.method,
            route: endpoint.route.constantRoute,
            query: endpoint.query.constant,
            requestQueryItems: [],
            response: endpoint.response,
            endpointHeaders: endpoint.constantHeaders,
            body: RequestBody(body: body, encoding: endpoint.bodyEncoding),
            jsonEncoderConfiguration: endpoint.jsonEncoderConfiguration,
            jsonDecoderConfiguration: endpoint.jsonDecoderConfiguration,
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
            endpointHeaders: endpointHeaders,
            requestHeaders: requestHeaders,
            body: body,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
        )
    }

    /// Returns a copy with a replacement request-level header layer.
    ///
    /// The supplied fields replace the complete request override layer. Endpoint and client
    /// fields remain available for names omitted from this layer.
    ///
    /// - Parameter fields: The request-level HTTP fields in caller-supplied order.
    /// - Returns: An immutable request copy with the replacement header layer.
    public func headers(_ fields: HTTPFields) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            requestQueryItems: requestQueryItems,
            response: response,
            endpointHeaders: endpointHeaders,
            requestHeaders: fields,
            body: body,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
        )
    }

    /// Returns a copy with one request-level field set or replaced.
    ///
    /// Existing values for `name` in the request layer are replaced; all other request fields
    /// are preserved.
    ///
    /// - Parameters:
    ///   - name: The HTTP field name to set.
    ///   - value: The replacement value.
    /// - Returns: An immutable request copy with the field-level override applied.
    public func header(_ name: HTTPField.Name, _ value: String) -> Self {
        var fields = requestHeaders
        fields[fields: name] = [HTTPField(name: name, value: value)]
        return Self(
            method: method,
            route: route,
            query: query,
            requestQueryItems: requestQueryItems,
            response: response,
            endpointHeaders: endpointHeaders,
            requestHeaders: fields,
            body: body,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
        )
    }
}
