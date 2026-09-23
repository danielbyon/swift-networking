//
//  Response.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

/// A decoded response value paired with the HTTP response that carried it.
public struct Response<Value: Sendable>: Sendable {
    /// The value decoded from the response body.
    public let value: Value

    /// The HTTP response metadata returned by the transport.
    public let httpResponse: HTTPResponse

    /// The identity of the logical execution that produced this response.
    public let requestID: RequestID

    package init(value: Value, httpResponse: HTTPResponse, requestID: RequestID) {
        self.value = value
        self.httpResponse = httpResponse
        self.requestID = requestID
    }
}

extension Response: Equatable where Value: Equatable {}

extension Response: Hashable where Value: Hashable {}
