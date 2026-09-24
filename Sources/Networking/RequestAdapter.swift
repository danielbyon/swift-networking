//
//  RequestAdapter.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

/// The immutable information available while adapting one prepared request.
public struct RequestAdaptationContext: Sendable {
    /// The current HTTP request, including mutations from earlier adapters.
    public let request: HTTPRequest

    /// The read-only body prepared for the pending transport attempt.
    public let body: PreparedRequestBody

    /// The identity assigned to this logical request execution.
    public let requestID: RequestID

    /// Typed metadata attached to the original request.
    public let context: RequestContext

    package init(
        request: HTTPRequest,
        body: PreparedRequestBody,
        requestID: RequestID,
        context: RequestContext,
    ) {
        self.request = request
        self.body = body
        self.requestID = requestID
        self.context = context
    }
}

/// An asynchronous request transformation applied before the request reaches transport.
public protocol RequestAdapter: Sendable {
    /// Returns the HTTP request that the next adapter or transport receives.
    ///
    /// Errors propagate unchanged and prevent later adapters and transport execution.
    ///
    /// - Parameter context: The current request and immutable execution metadata.
    /// - Returns: The adapted HTTP request.
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest
}

/// Stores a concrete or closure-backed request adapter behind one sendable value type.
public struct AnyRequestAdapter: RequestAdapter {
    private let adaptValue: @Sendable (RequestAdaptationContext) async throws -> HTTPRequest

    /// Wraps a concrete request adapter.
    ///
    /// - Parameter adapter: The adapter whose behavior this value erases.
    public init(_ adapter: some RequestAdapter) {
        adaptValue = { context in
            try await adapter.adapt(context)
        }
    }

    /// Creates an adapter from an asynchronous throwing closure.
    ///
    /// - Parameter adapt: The transformation to apply to each request.
    public init(
        adapt: @escaping @Sendable (RequestAdaptationContext) async throws -> HTTPRequest,
    ) {
        adaptValue = adapt
    }

    /// Returns the request produced by the stored adapter.
    public func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        try await adaptValue(context)
    }
}
