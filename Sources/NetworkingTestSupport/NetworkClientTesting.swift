//
//  NetworkClientTesting.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Networking

extension NetworkClient {
    /// Creates a real client that uses a TestSupport mock transport instead of URLSession.
    ///
    /// The returned client still runs request preparation, adapters, authentication, retry,
    /// response validation, decoding, and download finalization through the production pipeline.
    ///
    /// - Parameters:
    ///   - configuration: The immutable client configuration used for requests.
    ///   - transport: The actor-backed transport that supplies deterministic stub responses.
    /// - Returns: A configured client whose transport cannot fall through to live networking.
    public static func testing(
        configuration: Configuration = .init(),
        transport: MockNetworkTransport,
    ) throws -> NetworkClient {
        try NetworkClient(transport: transport, configuration: configuration)
    }
}
