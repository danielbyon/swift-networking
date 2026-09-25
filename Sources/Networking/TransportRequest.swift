//
//  TransportRequest.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

package struct TransportRequest: Sendable {
    package let httpRequest: HTTPRequest
    package let body: PreparedRequestBody
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
    ) {
        self.httpRequest = httpRequest
        self.body = body
        self.redirectPolicy = redirectPolicy
        self.requestID = requestID
        self.requestContext = requestContext
        self.attemptNumber = attemptNumber
    }
}
