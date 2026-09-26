//
//  TransportRequest.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Describes the URLSession task family and body representation for one transport attempt.
package enum TransportExecution: Sendable, Equatable {
    /// Sends no body or in-memory data through a URLSession data task.
    case data(body: Data?)

    /// Sends in-memory bytes through a URLSession upload task.
    case uploadFromData(Data)

    /// Sends the caller-owned local file through a URLSession upload task.
    case uploadFromFile(URL)

    /// Receives the response through a URLSession download task, optionally sending in-memory data.
    case download(body: Data?)

    /// Resolves operation/body compatibility before any transport attempt starts.
    package static func resolve(
        operation: EndpointOperation,
        body: PreparedRequestBody,
    ) -> Self? {
        switch operation {
        case .data:
            switch body {
            case .none:
                .data(body: nil)
            case let .data(data):
                .data(body: data)
            case let .file(url):
                .uploadFromFile(url)
            }
        case .upload:
            switch body {
            case .none:
                nil
            case let .data(data):
                .uploadFromData(data)
            case let .file(url):
                .uploadFromFile(url)
            }
        case .download:
            switch body {
            case .none:
                .download(body: nil)
            case let .data(data):
                .download(body: data)
            case .file:
                nil
            }
        }
    }
}

package struct TransportRequest: Sendable {
    package let httpRequest: HTTPRequest
    package let body: PreparedRequestBody
    /// The operation selected by the immutable endpoint contract.
    package let operation: EndpointOperation
    /// The preflight-approved URLSession task family, or nil for unsupported combinations.
    package let execution: TransportExecution?
    package let redirectPolicy: RedirectPolicy
    package let requestID: RequestID
    package let requestContext: RequestContext
    package let attemptNumber: UInt

    package init(
        httpRequest: HTTPRequest,
        body: PreparedRequestBody,
        redirectPolicy: RedirectPolicy = .follow,
        requestID: RequestID = RequestID(rawValue: UUID()),
        requestContext: RequestContext = RequestContext(),
        attemptNumber: UInt = 1,
        operation: EndpointOperation = .data,
        execution: TransportExecution? = nil,
    ) {
        self.httpRequest = httpRequest
        self.body = body
        self.operation = operation
        self.execution = execution ?? TransportExecution.resolve(operation: operation, body: body)
        self.redirectPolicy = redirectPolicy
        self.requestID = requestID
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
    }
}
