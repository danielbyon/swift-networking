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
    ///   - dependencies: The execution dependencies used for retry sleeping, wall-clock time, and
    ///     jitter. The default matches production behavior.
    /// - Returns: A configured client whose transport cannot fall through to live networking.
    public static func testing(
        configuration: Configuration = .init(),
        transport: MockNetworkTransport,
        dependencies: NetworkTestDependencies = .live,
    ) throws -> NetworkClient {
        try NetworkClient(
            transport: transport,
            configuration: configuration,
            retryTimingDependencies: RetryTimingDependencies(
                sleep: dependencies.sleep,
                now: dependencies.now,
                randomUnit: dependencies.randomUnit,
            ),
        )
    }
}
