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
    /// The immutable configuration used when creating a client.
    public struct Configuration: Sendable {
        package let requestIDGenerator: any RequestIDGenerator

        /// Creates the default client configuration.
        public init() {
            requestIDGenerator = UUIDRequestIDGenerator()
        }

        private init(requestIDGenerator: any RequestIDGenerator) {
            self.requestIDGenerator = requestIDGenerator
        }

        /// Returns a copy that uses the supplied logical-execution identity generator.
        ///
        /// - Parameter generator: The synchronous, nonthrowing generator to use for future
        ///   logical executions created by the client.
        /// - Returns: A configuration with the replacement generator.
        public func withRequestIDGenerator(_ generator: any RequestIDGenerator) -> Self {
            Self(requestIDGenerator: generator)
        }
    }

    private let transport: any NetworkTransport
    private let configuration: Configuration

    /// Creates a client that owns a foreground URL session for its requests.
    public convenience init() {
        self.init(transport: URLSessionTransport(), configuration: .init())
    }

    /// Creates a client from an immutable configuration and its owned foreground URL session.
    ///
    /// - Parameter configuration: The configuration used for logical request executions.
    public convenience init(configuration: Configuration) throws {
        self.init(transport: URLSessionTransport(), configuration: configuration)
    }

    package init(transport: any NetworkTransport, configuration: Configuration = .init()) {
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

        return NetworkTask(requestID: requestID) {
            let httpRequest = HTTPRequest(method: request.method, url: request.url)
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
        if Task.isCancelled {
            task.cancel()
        }

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}
