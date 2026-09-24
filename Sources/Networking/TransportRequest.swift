//
//  TransportRequest.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

package struct TransportRequest: Sendable {
    package let httpRequest: HTTPRequest
    package let body: PreparedRequestBody

    package init(httpRequest: HTTPRequest, body: PreparedRequestBody) {
        self.httpRequest = httpRequest
        self.body = body
    }
}
