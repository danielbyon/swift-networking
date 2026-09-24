//
//  StubNetworkTransport.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking

package enum StubTransportError: Error, Sendable, Equatable {
    case expectedFailure
}

/// A deterministic package-only transport for testing the Networking execution path.
package actor StubNetworkTransport: NetworkTransport {
    private enum Outcome: Sendable {
        case response(Data, HTTPResponse)
        case failure(StubTransportError)
    }

    private let outcome: Outcome
    private var requests: [TransportRequest] = []

    package init(response: Data, httpResponse: HTTPResponse) {
        outcome = .response(response, httpResponse)
    }

    package init(error: StubTransportError) {
        outcome = .failure(error)
    }

    package func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        switch outcome {
        case let .response(data, response):
            return (data, response)
        case let .failure(error):
            throw error
        }
    }

    package func receivedRequests() -> [HTTPRequest] {
        requests.map(\.httpRequest)
    }

    package func executionCount() -> Int {
        requests.count
    }
}
