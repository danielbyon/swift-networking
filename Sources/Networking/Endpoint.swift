//
//  Endpoint.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Selects how a request body is sent and how its response is handled.
package enum EndpointOperation: Sendable, Equatable {
    /// Keeps the response in memory for the endpoint's response decoder.
    case data

    /// Sends the required request body with upload-task semantics and decodes an in-memory response.
    case upload

    /// Writes the response to a temporary file and returns an owned download token.
    case download
}

/// Describes whether a response is decoded from bytes or transferred as an owned download file.
package enum EndpointResponseHandling<Output: Sendable>: Sendable {
    case decode(ResponseDecoding<Output>)
    case download(@Sendable (DownloadedFileStorage) -> Output)

    package var inferredAccept: String? {
        guard case let .decode(decoding) = self else {
            return nil
        }

        return decoding.inferredAccept
    }
}

/// A reusable HTTP contract that defines an operation's method, route, query, headers, authentication, and response handling.
public struct Endpoint<Input: Sendable, Body: Sendable, Output: Sendable>: Sendable {
    private enum HeaderStorage: Sendable {
        case fixed(HTTPFields)
        case inputDerived(@Sendable (Input) -> HTTPFields)
    }

    package let method: HTTPRequest.Method
    package let route: EndpointRoute<Input>
    package let query: QueryEncoding<Input>
    package let bodyEncoding: BodyEncoding<Body>
    /// The non-public operation semantics retained by every endpoint copy.
    package let operation: EndpointOperation
    package let response: EndpointResponseHandling<Output>
    package let authenticationRequirement: AuthenticationRequirement
    package let jsonEncoderConfiguration: JSONEncoderConfiguration
    package let jsonDecoderConfiguration: JSONDecoderConfiguration
    package let responseValidationPolicy: ResponseValidationPolicy?
    package let retryPolicy: RetryPolicy?
    package let redirectPolicy: RedirectPolicy?
    package let successfulResponseBodyRetentionPolicy: BodyRetentionPolicy?
    package let validationErrorBodyRetentionPolicy: BodyRetentionPolicy?
    private let headerStorage: HeaderStorage

    private init(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        query: QueryEncoding<Input>,
        bodyEncoding: BodyEncoding<Body>,
        operation: EndpointOperation,
        response: EndpointResponseHandling<Output>,
        authenticationRequirement: AuthenticationRequirement = .none,
        jsonEncoderConfiguration: @escaping JSONEncoderConfiguration = { _ in },
        jsonDecoderConfiguration: @escaping JSONDecoderConfiguration = { _ in },
        responseValidationPolicy: ResponseValidationPolicy? = nil,
        retryPolicy: RetryPolicy? = nil,
        redirectPolicy: RedirectPolicy? = nil,
        successfulResponseBodyRetentionPolicy: BodyRetentionPolicy? = nil,
        validationErrorBodyRetentionPolicy: BodyRetentionPolicy? = nil,
        headerStorage: HeaderStorage = .fixed(HTTPFields()),
    ) {
        self.method = method
        self.route = route
        self.query = query
        self.bodyEncoding = bodyEncoding
        self.operation = operation
        self.response = response
        self.authenticationRequirement = authenticationRequirement
        self.jsonEncoderConfiguration = jsonEncoderConfiguration
        self.jsonDecoderConfiguration = jsonDecoderConfiguration
        self.responseValidationPolicy = responseValidationPolicy
        self.retryPolicy = retryPolicy
        self.redirectPolicy = redirectPolicy
        self.successfulResponseBodyRetentionPolicy = successfulResponseBodyRetentionPolicy
        self.validationErrorBodyRetentionPolicy = validationErrorBodyRetentionPolicy
        self.headerStorage = headerStorage
    }

    private func replacingHeaderStorage(_ headerStorage: HeaderStorage) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns an internal endpoint copy with the selected operation semantics.
    ///
    /// This package-scoped seam allows execution preflight to validate operation/body
    /// compatibility independently of the public endpoint factories.
    package func withOperation(_ selectedOperation: EndpointOperation) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: selectedOperation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
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

    /// Returns a copy that configures the fresh JSON encoder used for this endpoint's bodies.
    ///
    /// The client configuration runs first, followed by endpoint configurations in modifier order.
    ///
    /// - Parameter configure: A Sendable configuration closure applied to each fresh encoder.
    /// - Returns: An endpoint copy with the supplied JSON encoder configuration.
    public func jsonEncoderConfiguration(
        _ configure: @escaping @Sendable (JSONEncoder) -> Void,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: { encoder in
                jsonEncoderConfiguration(encoder)
                configure(encoder)
            },
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy that configures the fresh JSON decoder used for this endpoint's responses.
    ///
    /// The client configuration runs first, followed by endpoint configurations in modifier order.
    ///
    /// - Parameter configure: A Sendable configuration closure applied to each fresh decoder.
    /// - Returns: An endpoint copy with the supplied JSON decoder configuration.
    public func jsonDecoderConfiguration(
        _ configure: @escaping @Sendable (JSONDecoder) -> Void,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: { decoder in
                jsonDecoderConfiguration(decoder)
                configure(decoder)
            },
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with a replacement response-validation policy.
    ///
    /// The endpoint policy replaces the client policy for requests created from this endpoint.
    public func validationPolicy(_ policy: ResponseValidationPolicy) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: policy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with a replacement successful-response body-retention policy.
    public func successfulResponseBodyRetentionPolicy(_ policy: BodyRetentionPolicy) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: policy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with a replacement validation-error body-retention policy.
    public func validationErrorBodyRetentionPolicy(_ policy: BodyRetentionPolicy) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: policy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with the endpoint's authentication and replay requirement.
    ///
    /// Requests created from this endpoint capture the requirement and cannot override it.
    public func authenticationRequirement(_ requirement: AuthenticationRequirement) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: requirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with a replacement retry policy for requests created from this endpoint.
    ///
    /// The endpoint policy replaces the client policy. Requests can replace it again.
    public func retryPolicy(_ policy: RetryPolicy) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: policy,
            redirectPolicy: redirectPolicy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
    }

    /// Returns a copy with a policy built from fresh default configuration.
    ///
    /// The builder replaces the endpoint policy as a whole and does not inherit client settings.
    public func retryPolicy(
        configure: @Sendable (inout RetryPolicy.Configuration) -> Void,
    ) -> Self {
        retryPolicy(RetryPolicy(configure: configure))
    }

    /// Returns a copy with a replacement redirect policy for requests created from this endpoint.
    ///
    /// The endpoint policy replaces the client policy. Requests can replace it again.
    public func redirectPolicy(_ policy: RedirectPolicy) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: bodyEncoding,
            operation: operation,
            response: response,
            authenticationRequirement: authenticationRequirement,
            jsonEncoderConfiguration: jsonEncoderConfiguration,
            jsonDecoderConfiguration: jsonDecoderConfiguration,
            responseValidationPolicy: responseValidationPolicy,
            retryPolicy: retryPolicy,
            redirectPolicy: policy,
            successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicy,
            headerStorage: headerStorage,
        )
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
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: .bodyless,
            operation: .data,
            response: .decode(response),
        )
    }
}

extension Endpoint {
    /// Creates a data endpoint that prepares its body for each transport attempt.
    ///
    /// - Parameters:
    ///   - method: The explicit HTTP method for every invocation.
    ///   - route: The endpoint-owned route.
    ///   - body: The strategy used to prepare the immutable body value.
    ///   - response: The response decoding strategy.
    ///   - query: The endpoint-owned query mechanism, defaulting to no endpoint query values.
    /// - Returns: An immutable bodyful data endpoint.
    public static func data(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        body: BodyEncoding<Body>,
        response: ResponseDecoding<Output>,
        query: QueryEncoding<Input> = .none,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: body,
            operation: .data,
            response: .decode(response),
        )
    }
}

extension Endpoint {
    /// Creates a bodyful upload endpoint whose response uses the supplied in-memory decoder.
    ///
    /// Upload endpoints always retain a body contract and use upload-task semantics for each
    /// transport attempt.
    ///
    /// - Parameters:
    ///   - method: The explicit HTTP method for every invocation.
    ///   - route: The endpoint-owned route.
    ///   - body: The strategy used to prepare the immutable request body.
    ///   - response: The response decoding strategy.
    ///   - query: The endpoint-owned query mechanism, defaulting to no endpoint query values.
    /// - Returns: An immutable upload endpoint.
    public static func upload(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        body: BodyEncoding<Body>,
        response: ResponseDecoding<Output>,
        query: QueryEncoding<Input> = .none,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: body,
            operation: .upload,
            response: .decode(response),
        )
    }
}

extension Endpoint where Body == Never, Output == DownloadedFile {
    /// Creates a bodyless download endpoint that returns the accepted response as an owned file.
    ///
    /// The endpoint does not decode response bytes or infer an `Accept` field from a decoder.
    ///
    /// - Parameters:
    ///   - method: The explicit HTTP method for every invocation.
    ///   - route: The endpoint-owned route.
    ///   - query: The endpoint-owned query mechanism, defaulting to no endpoint query values.
    /// - Returns: An immutable bodyless download endpoint.
    public static func download(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        query: QueryEncoding<Input> = .none,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: .bodyless,
            operation: .download,
            response: .download { DownloadedFile(ownership: $0) },
        )
    }
}

extension Endpoint where Output == DownloadedFile {
    /// Creates a download endpoint that prepares an in-memory request body for each attempt.
    ///
    /// A file-backed prepared request body is rejected during preflight before any attempt starts.
    /// The response is not decoded from memory and does not infer an `Accept` field from a decoder.
    ///
    /// - Parameters:
    ///   - method: The explicit HTTP method for every invocation.
    ///   - route: The endpoint-owned route.
    ///   - body: The strategy used to prepare the immutable request body for each attempt.
    ///   - query: The endpoint-owned query mechanism, defaulting to no endpoint query values.
    /// - Returns: An immutable bodyful download endpoint.
    public static func download(
        method: HTTPRequest.Method,
        route: EndpointRoute<Input>,
        body: BodyEncoding<Body>,
        query: QueryEncoding<Input> = .none,
    ) -> Self {
        Self(
            method: method,
            route: route,
            query: query,
            bodyEncoding: body,
            operation: .download,
            response: .download { DownloadedFile(ownership: $0) },
        )
    }
}
