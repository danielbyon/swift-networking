//
//  NetworkClient.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import HTTPTypesFoundation

package protocol NetworkTransport: Sendable {
    func execute(_ request: HTTPRequest) async throws -> (Data, HTTPResponse)
}

/// Creates the foreground session configuration with Networking's ambient stores disabled.
package func makeForegroundURLSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return configuration
}

private struct URLSessionTransport: NetworkTransport {
    private let session: URLSession

    init() {
        session = URLSession(configuration: makeForegroundURLSessionConfiguration())
    }

    func execute(_ request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        try await session.data(for: request)
    }
}

/// An immutable execution environment that owns its foreground URL session.
public final class NetworkClient: Sendable {
    /// Describes every invalid base URL setting discovered during client initialization.
    public struct ConfigurationError: Error, Sendable, Equatable {
        /// Identifies the base URL rule that failed validation.
        public enum Failure: Sendable, Equatable {
            /// The base URL does not use the HTTP or HTTPS scheme.
            case baseURLScheme

            /// The base URL contains a query component.
            case baseURLQuery

            /// The base URL contains a fragment component.
            case baseURLFragment
        }

        /// The failures in stable scheme, query, fragment order.
        public let failures: [Failure]

        package init(failures: [Failure]) {
            self.failures = failures
        }
    }

    /// The immutable configuration used when creating a client.
    public struct Configuration: Sendable {
        /// The optional HTTP or HTTPS base URL used to compose relative routes.
        public let baseURL: URL?

        package let requestIDGenerator: any RequestIDGenerator

        /// Creates client configuration with an optional base URL.
        ///
        /// - Parameter baseURL: The HTTP or HTTPS base URL used for relative routes. It must not
        ///   contain a query or fragment.
        public init(baseURL: URL? = nil) {
            self.baseURL = baseURL
            requestIDGenerator = UUIDRequestIDGenerator()
        }

        private init(baseURL: URL?, requestIDGenerator: any RequestIDGenerator) {
            self.baseURL = baseURL
            self.requestIDGenerator = requestIDGenerator
        }

        /// Returns a copy that uses the supplied logical-execution identity generator.
        ///
        /// - Parameter generator: The synchronous, nonthrowing generator to use for future
        ///   logical executions created by the client.
        /// - Returns: A configuration with the replacement generator.
        public func withRequestIDGenerator(_ generator: any RequestIDGenerator) -> Self {
            Self(baseURL: baseURL, requestIDGenerator: generator)
        }
    }

    private let transport: any NetworkTransport
    private let configuration: Configuration

    /// Creates a client that owns a foreground URL session for its requests.
    public convenience init() {
        self.init(validatedTransport: URLSessionTransport(), configuration: .init())
    }

    /// Creates a client from an immutable configuration and its owned foreground URL session.
    ///
    /// - Parameter configuration: The configuration used for logical request executions.
    public convenience init(configuration: Configuration) throws {
        try Self.validate(configuration)
        self.init(validatedTransport: URLSessionTransport(), configuration: configuration)
    }

    /// Creates a client that owns a foreground URL session and uses the supplied base URL.
    ///
    /// - Parameter baseURL: The HTTP or HTTPS base URL used for relative routes. It must not
    ///   contain a query or fragment.
    public convenience init(baseURL: URL?) throws {
        try self.init(configuration: Configuration(baseURL: baseURL))
    }

    package convenience init(transport: any NetworkTransport, configuration: Configuration = .init()) throws {
        try Self.validate(configuration)
        self.init(validatedTransport: transport, configuration: configuration)
    }

    private init(validatedTransport transport: any NetworkTransport, configuration: Configuration) {
        self.transport = transport
        self.configuration = configuration
    }

    /// Starts a shared logical execution immediately.
    ///
    /// - Parameter request: The immutable endpoint invocation to execute.
    /// - Returns: A shared task whose value is produced by exactly one execution.
    public func task<Output: Sendable>(for request: Request<Output>) -> NetworkTask<Output> {
        let requestID = configuration.requestIDGenerator.generateRequestID()
        let networkTransport = transport
        let baseURL = configuration.baseURL

        return NetworkTask(requestID: requestID) {
            let url = try Self.preflightURL(for: request.route, baseURL: baseURL, requestID: requestID)
            let httpRequest = HTTPRequest(method: request.method, url: url)
            let (data, httpResponse) = try await networkTransport.execute(httpRequest)
            let value = try request.response.decode(data, response: httpResponse)
            return Response(value: value, httpResponse: httpResponse, requestID: requestID)
        }
    }

    /// Executes a request and returns its decoded value and HTTP response.
    ///
    /// Transport and decoding errors are propagated unchanged.
    ///
    /// - Parameter request: The immutable endpoint invocation to execute.
    /// - Returns: The decoded response and its HTTP metadata.
    public func send<Output: Sendable>(_ request: Request<Output>) async throws -> Response<Output> {
        let task = task(for: request)

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private static func validate(_ configuration: Configuration) throws {
        guard let baseURL = configuration.baseURL else {
            return
        }
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError(failures: [.baseURLScheme])
        }

        let scheme = components.scheme?.lowercased()
        var failures: [ConfigurationError.Failure] = []
        if scheme != "http", scheme != "https" {
            failures.append(.baseURLScheme)
        }
        if components.percentEncodedQuery != nil {
            failures.append(.baseURLQuery)
        }
        if components.percentEncodedFragment != nil {
            failures.append(.baseURLFragment)
        }

        guard failures.isEmpty else {
            throw ConfigurationError(failures: failures)
        }
    }

    private static func preflightURL(
        for route: ResolvedEndpointRoute,
        baseURL: URL?,
        requestID: RequestID,
    ) throws -> URL {
        switch route {
        case let .absolute(url):
            return try absoluteURL(url, requestID: requestID)
        case let .relative(pathComponents):
            guard let baseURL else {
                throw RequestConstructionError(
                    requestID: requestID,
                    reason: .relativeRouteRequiresBaseURL,
                )
            }

            return try relativeURL(pathComponents, baseURL: baseURL, requestID: requestID)
        }
    }

    private static func absoluteURL(_ url: URL, requestID: RequestID) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard let scheme = components.scheme else {
            throw RequestConstructionError(requestID: requestID, reason: .missingURLScheme)
        }
        guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else {
            throw RequestConstructionError(
                requestID: requestID,
                reason: .unsupportedURLScheme(scheme),
            )
        }
        guard let host = components.host, !host.isEmpty else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        components.fragment = nil
        guard let resolvedURL = components.url else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return resolvedURL
    }

    private static func relativeURL(
        _ pathComponents: [String],
        baseURL: URL,
        requestID: RequestID,
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard let host = components.host, !host.isEmpty else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard !pathComponents.isEmpty else {
            return baseURL
        }

        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        } else if !path.hasSuffix("/") {
            path.append("/")
        }

        let encodedComponents = try pathComponents.map { component in
            try percentEncodePathComponent(component, requestID: requestID)
        }
        components.percentEncodedPath = path + encodedComponents.joined(separator: "/")

        guard let resolvedURL = components.url else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return resolvedURL
    }

    private static func percentEncodePathComponent(_ component: String, requestID: RequestID) throws -> String {
        var allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@",
        )
        allowedCharacters.remove(charactersIn: ".")

        guard let encodedComponent = component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return encodedComponent
    }
}
