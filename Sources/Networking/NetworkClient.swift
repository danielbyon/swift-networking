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
    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse)
}

/// Creates a foreground session configuration using the client's policy defaults.
///
/// URL cache and cookie storage use the client values, while credential storage remains disabled.
/// Unspecified session options retain Foundation's defaults.
package func makeForegroundURLSessionConfiguration(
    configuration clientConfiguration: NetworkClient.Configuration = .init(),
) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = clientConfiguration.urlCache
    configuration.httpCookieStorage = clientConfiguration.httpCookieStorage
    configuration.urlCredentialStorage = nil

    if let requestTimeout = clientConfiguration.requestTimeout {
        configuration.timeoutIntervalForRequest = durationTimeInterval(requestTimeout)
    }
    if let resourceTimeout = clientConfiguration.resourceTimeout {
        configuration.timeoutIntervalForResource = durationTimeInterval(resourceTimeout)
    }
    if let waitsForConnectivity = clientConfiguration.waitsForConnectivity {
        configuration.waitsForConnectivity = waitsForConnectivity
    }
    if let allowsExpensiveNetworkAccess = clientConfiguration.allowsExpensiveNetworkAccess {
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
    }
    if let allowsConstrainedNetworkAccess = clientConfiguration.allowsConstrainedNetworkAccess {
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }
    if let allowsCellularAccess = clientConfiguration.allowsCellularAccess {
        configuration.allowsCellularAccess = allowsCellularAccess
    }
    if let cachePolicy = clientConfiguration.cachePolicy {
        configuration.requestCachePolicy = cachePolicy
    }

    return configuration
}

/// Converts an HTTP request into the Foundation request sent by URLSession.
///
/// - Parameters:
///   - request: The finalized HTTP request produced by client routing and composition.
///   - assumesHTTP3Capable: The optional client preference to apply to the first attempt.
/// - Returns: The Foundation request, or nil when it cannot represent the HTTP request.
package func makeURLRequest(
    _ request: HTTPRequest,
    assumesHTTP3Capable: Bool?,
) -> URLRequest? {
    guard var urlRequest = URLRequest(httpRequest: request) else {
        return nil
    }

    if let assumesHTTP3Capable {
        urlRequest.assumesHTTP3Capable = assumesHTTP3Capable
    }

    return urlRequest
}

/// Converts transport metadata and an in-memory body into the Foundation request used by URLSession.
///
/// File-backed bodies are not representable by this foreground data-task adapter and return nil.
package func makeURLRequest(
    _ request: TransportRequest,
    assumesHTTP3Capable: Bool?,
) -> URLRequest? {
    guard var urlRequest = makeURLRequest(
        request.httpRequest,
        assumesHTTP3Capable: assumesHTTP3Capable,
    ) else {
        return nil
    }

    switch request.body {
    case .none:
        break
    case let .data(data):
        urlRequest.httpBody = data
    case .file:
        return nil
    }

    return urlRequest
}

/// Converts a positive Swift duration into Foundation's seconds-based timeout value.
private func durationTimeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

private struct URLSessionTransport: NetworkTransport {
    private let session: URLSession
    private let assumesHTTP3Capable: Bool?

    init(configuration: NetworkClient.Configuration) {
        session = URLSession(
            configuration: makeForegroundURLSessionConfiguration(configuration: configuration),
        )
        assumesHTTP3Capable = configuration.assumesHTTP3Capable
    }

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        guard let urlRequest = makeURLRequest(
            request,
            assumesHTTP3Capable: assumesHTTP3Capable,
        ) else {
            throw URLError(.badURL)
        }

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let response = (urlResponse as? HTTPURLResponse)?.httpResponse else {
            throw URLError(.badServerResponse)
        }

        return (data, response)
    }
}

/// Selects whether an immutable configuration field keeps its current value or receives a replacement.
private enum ConfigurationFieldUpdate<Value> {
    case unchanged
    case set(Value)

    func applying(to currentValue: Value) -> Value {
        switch self {
        case .unchanged:
            currentValue
        case let .set(value):
            value
        }
    }
}

/// An immutable execution environment that owns its foreground URL session.
public final class NetworkClient: Sendable {
    /// Describes every invalid base URL or timeout setting discovered during client initialization.
    public struct ConfigurationError: Error, Sendable, Equatable {
        /// Identifies a base URL rule or timeout policy that failed validation.
        public enum Failure: Sendable, Equatable {
            /// The base URL does not use the HTTP or HTTPS scheme.
            case baseURLScheme

            /// The base URL contains a query component.
            case baseURLQuery

            /// The base URL contains a fragment component.
            case baseURLFragment

            /// The client request timeout is zero or negative.
            case requestTimeout

            /// The client resource timeout is zero or negative.
            case resourceTimeout
        }

        /// The failures in stable base URL, request timeout, resource timeout order.
        public let failures: [Failure]

        package init(failures: [Failure]) {
            self.failures = failures
        }
    }

    /// The immutable configuration used when creating a client.
    public struct Configuration: Sendable {
        /// The optional HTTP or HTTPS base URL used to compose relative routes.
        public let baseURL: URL?

        /// Client-wide default HTTP fields applied before endpoint and request fields.
        public let defaultHeaders: HTTPFields

        /// Static query items applied to relative routes before endpoint and request query items.
        public let defaultQueryItems: [URLQueryItem]

        /// Client-wide defaults for Codable query serialization.
        public let urlQueryEncoderConfiguration: URLQueryEncoder.Configuration

        /// Client-wide configuration applied to each fresh JSON request encoder.
        public let jsonEncoderConfiguration: @Sendable (JSONEncoder) -> Void

        /// Client-wide configuration applied to each fresh JSON response decoder.
        public let jsonDecoderConfiguration: @Sendable (JSONDecoder) -> Void

        /// The URL cache used by the foreground session. A nil value disables URL caching.
        public let urlCache: URLCache?

        /// The cookie storage used by the foreground session. A nil value disables cookie storage.
        public let httpCookieStorage: HTTPCookieStorage?

        /// The client-wide request timeout, or nil to preserve Foundation's default.
        ///
        /// An explicit value must be greater than zero when a client is created.
        public let requestTimeout: Duration?

        /// The client-wide resource timeout, or nil to preserve Foundation's default.
        ///
        /// An explicit value must be greater than zero when a client is created.
        public let resourceTimeout: Duration?

        /// Whether the foreground session waits for connectivity, or nil to preserve its default.
        public let waitsForConnectivity: Bool?

        /// Whether the foreground session may use expensive networks, or nil to preserve its default.
        public let allowsExpensiveNetworkAccess: Bool?

        /// Whether the foreground session may use constrained networks, or nil to preserve its default.
        public let allowsConstrainedNetworkAccess: Bool?

        /// Whether the foreground session may use cellular networks, or nil to preserve its default.
        public let allowsCellularAccess: Bool?

        /// The cache policy used by the foreground session, or nil to preserve Foundation's default.
        public let cachePolicy: URLRequest.CachePolicy?

        /// The HTTP/3 first-attempt preference for outgoing requests, or nil to preserve Foundation's value.
        public let assumesHTTP3Capable: Bool?

        package let requestIDGenerator: any RequestIDGenerator
        package let requestAdapters: [AnyRequestAdapter]

        /// Creates client configuration with an optional base URL.
        ///
        /// - Parameter baseURL: The HTTP or HTTPS base URL used for relative routes. It must not
        ///   contain a query or fragment.
        public init(baseURL: URL? = nil) {
            self.baseURL = baseURL
            defaultHeaders = HTTPFields()
            defaultQueryItems = []
            urlQueryEncoderConfiguration = .init()
            jsonEncoderConfiguration = { _ in }
            jsonDecoderConfiguration = { _ in }
            urlCache = nil
            httpCookieStorage = nil
            requestTimeout = nil
            resourceTimeout = nil
            waitsForConnectivity = nil
            allowsExpensiveNetworkAccess = nil
            allowsConstrainedNetworkAccess = nil
            allowsCellularAccess = nil
            cachePolicy = nil
            assumesHTTP3Capable = nil
            requestIDGenerator = UUIDRequestIDGenerator()
            requestAdapters = []
        }

        private init(
            baseURL: URL?,
            defaultHeaders: HTTPFields,
            defaultQueryItems: [URLQueryItem],
            urlQueryEncoderConfiguration: URLQueryEncoder.Configuration,
            jsonEncoderConfiguration: @escaping JSONEncoderConfiguration,
            jsonDecoderConfiguration: @escaping JSONDecoderConfiguration,
            urlCache: URLCache?,
            httpCookieStorage: HTTPCookieStorage?,
            requestTimeout: Duration?,
            resourceTimeout: Duration?,
            waitsForConnectivity: Bool?,
            allowsExpensiveNetworkAccess: Bool?,
            allowsConstrainedNetworkAccess: Bool?,
            allowsCellularAccess: Bool?,
            cachePolicy: URLRequest.CachePolicy?,
            assumesHTTP3Capable: Bool?,
            requestIDGenerator: any RequestIDGenerator,
            requestAdapters: [AnyRequestAdapter],
        ) {
            self.baseURL = baseURL
            self.defaultHeaders = defaultHeaders
            self.defaultQueryItems = defaultQueryItems
            self.urlQueryEncoderConfiguration = urlQueryEncoderConfiguration
            self.jsonEncoderConfiguration = jsonEncoderConfiguration
            self.jsonDecoderConfiguration = jsonDecoderConfiguration
            self.urlCache = urlCache
            self.httpCookieStorage = httpCookieStorage
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
            self.waitsForConnectivity = waitsForConnectivity
            self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
            self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
            self.allowsCellularAccess = allowsCellularAccess
            self.cachePolicy = cachePolicy
            self.assumesHTTP3Capable = assumesHTTP3Capable
            self.requestIDGenerator = requestIDGenerator
            self.requestAdapters = requestAdapters
        }

        /// Returns a copy with replacement static query items for relative routes.
        ///
        /// - Parameter queryItems: The static client query items in caller-supplied order.
        /// - Returns: A configuration with the replacement default query layer.
        public func withDefaultQueryItems(_ queryItems: [URLQueryItem]) -> Self {
            copying(defaultQueryItems: .set(queryItems))
        }

        /// Returns a copy with replacement client-wide Codable query encoder defaults.
        ///
        /// - Parameter configuration: The strategy overrides used by future logical executions.
        /// - Returns: A configuration with the replacement encoder defaults.
        public func withURLQueryEncoderConfiguration(
            _ configuration: URLQueryEncoder.Configuration,
        ) -> Self {
            copying(urlQueryEncoderConfiguration: .set(configuration))
        }

        /// Returns a copy with replacement client-wide JSON encoder configuration.
        ///
        /// The closure is applied to a new library-owned `JSONEncoder` for every JSON body encoding.
        ///
        /// - Parameter configure: A Sendable closure that configures each fresh JSON encoder.
        /// - Returns: A configuration with the replacement JSON encoder configuration.
        public func withJSONEncoderConfiguration(
            _ configure: @escaping @Sendable (JSONEncoder) -> Void,
        ) -> Self {
            copying(jsonEncoderConfiguration: .set(configure))
        }

        /// Returns a copy with replacement client-wide JSON decoder configuration.
        ///
        /// The closure is applied to a new library-owned `JSONDecoder` for every JSON response decode.
        ///
        /// - Parameter configure: A Sendable closure that configures each fresh JSON decoder.
        /// - Returns: A configuration with the replacement JSON decoder configuration.
        public func withJSONDecoderConfiguration(
            _ configure: @escaping @Sendable (JSONDecoder) -> Void,
        ) -> Self {
            copying(jsonDecoderConfiguration: .set(configure))
        }

        /// Returns a copy that uses the supplied logical-execution identity generator.
        ///
        /// - Parameter generator: The synchronous, nonthrowing generator to use for future
        ///   logical executions created by the client.
        /// - Returns: A configuration with the replacement generator.
        public func withRequestIDGenerator(_ generator: any RequestIDGenerator) -> Self {
            copying(requestIDGenerator: .set(generator))
        }

        /// Returns a copy with one adapter appended to the client execution order.
        ///
        /// Adapters run after body preparation and receive the request returned by the previous
        /// adapter. Repeated calls append in call order.
        ///
        /// - Parameter adapter: The adapter to append.
        /// - Returns: A configuration with the adapter added after existing adapters.
        public func withRequestAdapter(_ adapter: some RequestAdapter) -> Self {
            copying(requestAdapters: .set(requestAdapters + [AnyRequestAdapter(adapter)]))
        }

        /// Returns a copy with replacement client-wide default HTTP fields.
        ///
        /// - Parameter fields: The client defaults in caller-supplied order.
        /// - Returns: A configuration with the replacement client header layer.
        public func withDefaultHeaders(_ fields: HTTPFields) -> Self {
            copying(defaultHeaders: .set(fields))
        }

        /// Returns a copy using the supplied URL cache.
        ///
        /// A nil cache disables URL caching.
        public func withURLCache(_ urlCache: URLCache?) -> Self {
            copying(urlCache: .set(urlCache))
        }

        /// Returns a copy using the supplied cookie storage.
        ///
        /// A nil storage disables cookie storage.
        public func withHTTPCookieStorage(_ httpCookieStorage: HTTPCookieStorage?) -> Self {
            copying(httpCookieStorage: .set(httpCookieStorage))
        }

        /// Returns a copy using the supplied client request timeout.
        ///
        /// A nil timeout preserves Foundation's default. An explicit timeout must be greater than zero.
        public func withRequestTimeout(_ requestTimeout: Duration?) -> Self {
            copying(requestTimeout: .set(requestTimeout))
        }

        /// Returns a copy using the supplied client resource timeout.
        ///
        /// A nil timeout preserves Foundation's default. An explicit timeout must be greater than zero.
        public func withResourceTimeout(_ resourceTimeout: Duration?) -> Self {
            copying(resourceTimeout: .set(resourceTimeout))
        }

        /// Returns a copy with the supplied waits-for-connectivity setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withWaitsForConnectivity(_ waitsForConnectivity: Bool?) -> Self {
            copying(waitsForConnectivity: .set(waitsForConnectivity))
        }

        /// Returns a copy with the supplied expensive-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsExpensiveNetworkAccess(_ allowsExpensiveNetworkAccess: Bool?) -> Self {
            copying(allowsExpensiveNetworkAccess: .set(allowsExpensiveNetworkAccess))
        }

        /// Returns a copy with the supplied constrained-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsConstrainedNetworkAccess(_ allowsConstrainedNetworkAccess: Bool?) -> Self {
            copying(allowsConstrainedNetworkAccess: .set(allowsConstrainedNetworkAccess))
        }

        /// Returns a copy with the supplied cellular-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsCellularAccess(_ allowsCellularAccess: Bool?) -> Self {
            copying(allowsCellularAccess: .set(allowsCellularAccess))
        }

        /// Returns a copy with the supplied Foundation request cache policy.
        ///
        /// A nil policy preserves Foundation's default.
        public func withCachePolicy(_ cachePolicy: URLRequest.CachePolicy?) -> Self {
            copying(cachePolicy: .set(cachePolicy))
        }

        /// Returns a copy with the supplied HTTP/3 first-attempt preference.
        ///
        /// A nil value leaves Foundation's generated URLRequest preference unchanged.
        public func withAssumesHTTP3Capable(_ assumesHTTP3Capable: Bool?) -> Self {
            copying(assumesHTTP3Capable: .set(assumesHTTP3Capable))
        }

        /// Returns an immutable copy with selected fields replaced.
        ///
        /// Fields marked unchanged keep their current values. A set update replaces the field,
        /// including when the replacement value is nil.
        private func copying(
            baseURL baseURLUpdate: ConfigurationFieldUpdate<URL?> = .unchanged,
            defaultHeaders defaultHeadersUpdate: ConfigurationFieldUpdate<HTTPFields> = .unchanged,
            defaultQueryItems defaultQueryItemsUpdate: ConfigurationFieldUpdate<[URLQueryItem]> = .unchanged,
            urlQueryEncoderConfiguration urlQueryEncoderConfigurationUpdate: ConfigurationFieldUpdate<URLQueryEncoder
                .Configuration> = .unchanged,
            jsonEncoderConfiguration jsonEncoderConfigurationUpdate: ConfigurationFieldUpdate<
                JSONEncoderConfiguration,
            > = .unchanged,
            jsonDecoderConfiguration jsonDecoderConfigurationUpdate: ConfigurationFieldUpdate<
                JSONDecoderConfiguration,
            > = .unchanged,
            urlCache urlCacheUpdate: ConfigurationFieldUpdate<URLCache?> = .unchanged,
            httpCookieStorage httpCookieStorageUpdate: ConfigurationFieldUpdate<HTTPCookieStorage?> = .unchanged,
            requestTimeout requestTimeoutUpdate: ConfigurationFieldUpdate<Duration?> = .unchanged,
            resourceTimeout resourceTimeoutUpdate: ConfigurationFieldUpdate<Duration?> = .unchanged,
            waitsForConnectivity waitsForConnectivityUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            allowsExpensiveNetworkAccess allowsExpensiveNetworkAccessUpdate: ConfigurationFieldUpdate<Bool?> =
                .unchanged,
            allowsConstrainedNetworkAccess allowsConstrainedNetworkAccessUpdate: ConfigurationFieldUpdate<Bool?> =
                .unchanged,
            allowsCellularAccess allowsCellularAccessUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            cachePolicy cachePolicyUpdate: ConfigurationFieldUpdate<URLRequest.CachePolicy?> = .unchanged,
            assumesHTTP3Capable assumesHTTP3CapableUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            requestIDGenerator requestIDGeneratorUpdate: ConfigurationFieldUpdate<any RequestIDGenerator> = .unchanged,
            requestAdapters requestAdaptersUpdate: ConfigurationFieldUpdate<[AnyRequestAdapter]> = .unchanged,
        ) -> Self {
            Self(
                baseURL: baseURLUpdate.applying(to: baseURL),
                defaultHeaders: defaultHeadersUpdate.applying(to: defaultHeaders),
                defaultQueryItems: defaultQueryItemsUpdate.applying(to: defaultQueryItems),
                urlQueryEncoderConfiguration: urlQueryEncoderConfigurationUpdate.applying(
                    to: urlQueryEncoderConfiguration,
                ),
                jsonEncoderConfiguration: jsonEncoderConfigurationUpdate.applying(
                    to: jsonEncoderConfiguration,
                ),
                jsonDecoderConfiguration: jsonDecoderConfigurationUpdate.applying(
                    to: jsonDecoderConfiguration,
                ),
                urlCache: urlCacheUpdate.applying(to: urlCache),
                httpCookieStorage: httpCookieStorageUpdate.applying(to: httpCookieStorage),
                requestTimeout: requestTimeoutUpdate.applying(to: requestTimeout),
                resourceTimeout: resourceTimeoutUpdate.applying(to: resourceTimeout),
                waitsForConnectivity: waitsForConnectivityUpdate.applying(to: waitsForConnectivity),
                allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccessUpdate.applying(
                    to: allowsExpensiveNetworkAccess,
                ),
                allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccessUpdate.applying(
                    to: allowsConstrainedNetworkAccess,
                ),
                allowsCellularAccess: allowsCellularAccessUpdate.applying(to: allowsCellularAccess),
                cachePolicy: cachePolicyUpdate.applying(to: cachePolicy),
                assumesHTTP3Capable: assumesHTTP3CapableUpdate.applying(to: assumesHTTP3Capable),
                requestIDGenerator: requestIDGeneratorUpdate.applying(to: requestIDGenerator),
                requestAdapters: requestAdaptersUpdate.applying(to: requestAdapters),
            )
        }
    }

    private let transport: any NetworkTransport
    private let configuration: Configuration

    /// Creates a client that owns a foreground URL session for its requests.
    public convenience init() {
        let defaultConfiguration = Configuration()
        do {
            try Self.validate(defaultConfiguration)
        } catch {
            preconditionFailure("The default NetworkClient configuration must be valid.")
        }
        self.init(
            validatedTransport: URLSessionTransport(configuration: defaultConfiguration),
            configuration: defaultConfiguration,
        )
    }

    /// Creates a client from an immutable configuration and its owned foreground URL session.
    ///
    /// - Parameter configuration: The configuration used for logical request executions.
    public convenience init(configuration: Configuration) throws {
        try Self.validate(configuration)
        self.init(
            validatedTransport: URLSessionTransport(configuration: configuration),
            configuration: configuration,
        )
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
        let clientDefaultHeaders = configuration.defaultHeaders
        let clientQueryItems = configuration.defaultQueryItems
        let clientEncoderConfiguration = configuration.urlQueryEncoderConfiguration
        let clientJSONEncoderConfiguration = configuration.jsonEncoderConfiguration
        let clientJSONDecoderConfiguration = configuration.jsonDecoderConfiguration
        let requestAdapters = configuration.requestAdapters
        let routeKind: QueryRouteKind =
            switch request.route {
            case .absolute:
                .absolute
            case .relative:
                .relative
            }

        return NetworkTask(requestID: requestID) {
            let routeURL = try Self.preflightURL(for: request.route, baseURL: baseURL, requestID: requestID)
            let url = try QueryComposer.compose(
                url: routeURL,
                routeKind: routeKind,
                clientQueryItems: clientQueryItems,
                clientEncoderConfiguration: clientEncoderConfiguration,
                endpointQuery: request.query,
                requestQueryItems: request.requestQueryItems,
                requestID: requestID,
            )
            let preparedBody = try request.body?.prepare(
                clientJSONEncoderConfiguration: clientJSONEncoderConfiguration,
                endpointJSONEncoderConfiguration: request.jsonEncoderConfiguration,
            ) ?? .none
            var inferredHeaders = preparedBody.inferredHeaders
            if let inferredAccept = request.response.inferredAccept {
                inferredHeaders[fields: .accept] = [HTTPField(name: .accept, value: inferredAccept)]
            }
            let headerFields = HeaderComposer.compose(
                libraryInferred: inferredHeaders,
                clientDefaults: clientDefaultHeaders,
                endpoint: request.endpointHeaders,
                request: request.requestHeaders,
            )
            let httpRequest = HTTPRequest(method: request.method, url: url, headerFields: headerFields)
            if case .file = preparedBody {
                throw RequestConstructionError(requestID: requestID, reason: .unsupportedOperationBodyCombination)
            }

            let bodyInspection = preparedBody.inspection
            var adaptedRequest = httpRequest
            for adapter in requestAdapters {
                adaptedRequest = try await adapter.adapt(
                    RequestAdaptationContext(
                        request: adaptedRequest,
                        body: bodyInspection,
                        requestID: requestID,
                        context: request.context,
                    ),
                )
            }

            let transportRequest = TransportRequest(
                httpRequest: adaptedRequest,
                body: bodyInspection,
            )
            let (data, httpResponse) = try await networkTransport.execute(transportRequest)
            let value = try request.response.decode(
                data,
                response: httpResponse,
                clientJSONDecoderConfiguration: clientJSONDecoderConfiguration,
                endpointJSONDecoderConfiguration: request.jsonDecoderConfiguration,
            )
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
        var failures: [ConfigurationError.Failure] = []

        if let baseURL = configuration.baseURL {
            if let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                let scheme = components.scheme?.lowercased()
                if scheme != "http", scheme != "https" {
                    failures.append(.baseURLScheme)
                }
                if components.percentEncodedQuery != nil {
                    failures.append(.baseURLQuery)
                }
                if components.percentEncodedFragment != nil {
                    failures.append(.baseURLFragment)
                }
            } else {
                failures.append(.baseURLScheme)
            }
        }

        if let requestTimeout = configuration.requestTimeout, requestTimeout <= .zero {
            failures.append(.requestTimeout)
        }
        if let resourceTimeout = configuration.resourceTimeout, resourceTimeout <= .zero {
            failures.append(.resourceTimeout)
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
        if component == "." {
            return "%2E"
        }
        if component == ".." {
            return "%2E%2E"
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@",
        )

        guard let encodedComponent = component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return encodedComponent
    }
}
