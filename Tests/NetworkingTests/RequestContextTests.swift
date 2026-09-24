//
//  RequestContextTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct RequestContextTests {
    @Test("An unset request context key returns nil")
    func unsetKeyReturnsNil() {
        #expect(RequestContext()[TraceKey.self] == nil)
    }

    @Test("Request context modifiers replace one key without mutating earlier copies")
    func requestContextModifiersReplaceOnlyTheSelectedKey() throws {
        let original = try makeRequest()
        let first = original
            .context(TraceKey.self, value: "first")
            .context(AttemptLabelKey.self, value: 7)
        let replacement = first.context(TraceKey.self, value: "second")

        #expect(original.context[TraceKey.self] == nil)
        #expect(first.context[TraceKey.self] == "first")
        #expect(first.context[AttemptLabelKey.self] == 7)
        #expect(replacement.context[TraceKey.self] == "second")
        #expect(replacement.context[AttemptLabelKey.self] == 7)
    }

    @Test("Diagnostic context includes only opted-in keys with fully qualified type names")
    func diagnosticRepresentationOmitsOrdinaryContextValues() throws {
        let request = try makeRequest()
            .context(PrivateTokenKey.self, value: "must-not-appear")
            .context(DiagnosticLabelKey.self, value: "profile")

        #expect(request.context.diagnosticRepresentation == [
            String(reflecting: DiagnosticLabelKey.self): "label=profile",
        ])
    }

    @Test("Diagnostic opt-in survives a generic RequestContextKey modifier")
    func genericModifierRetainsDiagnosticOptIn() throws {
        let original = try makeRequest()
        let request = attachContext(
            original,
            key: DiagnosticLabelKey.self,
            value: "profile",
        )

        #expect(request.context.diagnosticRepresentation == [
            String(reflecting: DiagnosticLabelKey.self): "label=profile",
        ])
    }

    private func makeRequest() throws -> Request<Data> {
        let url = try #require(URL(string: "https://example.com/context"))
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        return Request(endpoint: endpoint)
    }

    private func attachContext<Key: RequestContextKey>(
        _ request: Request<Data>,
        key: Key.Type,
        value: Key.Value,
    ) -> Request<Data> {
        request.context(key, value: value)
    }
}

private enum TraceKey: RequestContextKey {
    typealias Value = String
}

private enum AttemptLabelKey: RequestContextKey {
    typealias Value = Int
}

private enum PrivateTokenKey: RequestContextKey {
    typealias Value = String
}

private enum DiagnosticLabelKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "label=\(value)"
    }
}
