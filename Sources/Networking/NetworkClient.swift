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
    private let transport: any NetworkTransport

    /// Creates a client that owns a foreground URL session for its requests.
    public convenience init() {
        self.init(transport: URLSessionTransport())
    }

    package init(transport: any NetworkTransport) {
        self.transport = transport
    }

    /// Executes a request and returns its decoded value and HTTP response.
    ///
    /// Transport and decoding errors are propagated unchanged.
    ///
    /// - Parameter request: The immutable endpoint invocation to execute.
    /// - Returns: The decoded response and its HTTP metadata.
    public func send<Output: Sendable>(_ request: Request<Output>) async throws -> Response<Output> {
        let httpRequest = HTTPRequest(method: request.method, url: request.url)
        let (data, httpResponse) = try await transport.execute(httpRequest)
        let value = try request.response.decode(data, response: httpResponse)
        return Response(value: value, httpResponse: httpResponse)
    }
}
