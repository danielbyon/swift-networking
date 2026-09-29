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

    @Test("Diagnostic context includes only opted-in keys with normalized type names")
    func diagnosticRepresentationOmitsOrdinaryContextValues() throws {
        let request = try makeRequest()
            .context(PrivateTokenKey.self, value: "must-not-appear")
            .context(DiagnosticLabelKey.self, value: "profile")

        #expect(request.context.diagnosticRepresentation == [
            RequestContextDiagnosticEntry(key: "NetworkingTests.DiagnosticLabelKey", value: "label=profile"),
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
            RequestContextDiagnosticEntry(key: "NetworkingTests.DiagnosticLabelKey", value: "label=profile"),
        ])
    }

    @Test("Diagnostic context keys preserve generic argument identity deterministically")
    func diagnosticRepresentationDistinguishesGenericKeyArguments() {
        struct FirstArgument: Sendable {}
        struct SecondArgument: Sendable {}
        typealias FirstKey = GenericDiagnosticContextKey<DiagnosticArgumentBox<FirstArgument>>
        typealias SecondKey = GenericDiagnosticContextKey<DiagnosticArgumentBox<SecondArgument>>

        let context = RequestContext()
            .setting(FirstKey.self, value: "FIRST-GENERIC-CONTEXT-VALUE")
            .setting(SecondKey.self, value: "SECOND-GENERIC-CONTEXT-VALUE")
        let representation = context.diagnosticRepresentation
        let reversedRepresentation = RequestContext()
            .setting(SecondKey.self, value: "SECOND-GENERIC-CONTEXT-VALUE")
            .setting(FirstKey.self, value: "FIRST-GENERIC-CONTEXT-VALUE")
            .diagnosticRepresentation
        let names = representation.map(\.key)

        #expect(representation.count == 2)
        #expect(representation.map(\.value).contains("value=FIRST-GENERIC-CONTEXT-VALUE"))
        #expect(representation.map(\.value).contains("value=SECOND-GENERIC-CONTEXT-VALUE"))
        #expect(names.contains(where: { $0.contains("DiagnosticArgumentBox") && $0.contains("FirstArgument") }))
        #expect(names.contains(where: { $0.contains("DiagnosticArgumentBox") && $0.contains("SecondArgument") }))
        #expect(representation == reversedRepresentation)
        for name in names {
            #expect(!name.contains("unknown context at $"))
            #expect(!name.contains("$"))
            #expect(!name.contains("0x"))
        }
    }

    @Test("Diagnostic context keys preserve unsupported symbol identity deterministically")
    func symbolContextKeysStayDistinct() {
        let first = RequestContext().setting(Diagnostic🐶ContextKey.self, value: "DOG-SYMBOL-VALUE")
        let second = first.setting(Diagnostic🐱ContextKey.self, value: "CAT-SYMBOL-VALUE")
        let representation = second.diagnosticRepresentation
        let reversedRepresentation = RequestContext()
            .setting(Diagnostic🐱ContextKey.self, value: "CAT-SYMBOL-VALUE")
            .setting(Diagnostic🐶ContextKey.self, value: "DOG-SYMBOL-VALUE")
            .diagnosticRepresentation
        let names = representation.map(\.key)

        #expect(representation.count == 2)
        #expect(representation.map(\.value).contains("value=DOG-SYMBOL-VALUE"))
        #expect(representation.map(\.value).contains("value=CAT-SYMBOL-VALUE"))
        #expect(names.contains(where: { $0.contains("~u{1F436}") }))
        #expect(names.contains(where: { $0.contains("~u{1F431}") }))
        #expect(representation == reversedRepresentation)
        for name in names {
            #expect(!name.contains("unknown context at $"))
            #expect(!name.contains("$"))
            #expect(!name.lowercased().contains("0x"))
        }
    }

    @Test("Generic diagnostic keys retain arguments with ordinary 0x text")
    func hexLikeContextKeyArgumentsRemainDistinct() throws {
        let requestID = try RequestID(rawValue: #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000021"),
        ))
        let firstContext = RequestContext()
            .setting(GenericDiagnosticContextKey<DiagnosticArgumentBox<Key0xA>>.self, value: "KEY-0XA-VALUE")
            .setting(GenericDiagnosticContextKey<DiagnosticArgumentBox<Key0xB>>.self, value: "KEY-0XB-VALUE")
        let reversedContext = RequestContext()
            .setting(GenericDiagnosticContextKey<DiagnosticArgumentBox<Key0xB>>.self, value: "KEY-0XB-VALUE")
            .setting(GenericDiagnosticContextKey<DiagnosticArgumentBox<Key0xA>>.self, value: "KEY-0XA-VALUE")
        let message = diagnosticMessage(for: firstContext, requestID: requestID)
        let reversedMessage = diagnosticMessage(for: reversedContext, requestID: requestID)

        #expect(message.contains("KEY-0XA-VALUE"))
        #expect(message.contains("KEY-0XB-VALUE"))
        #expect(message.contains("Key0xA"))
        #expect(message.contains("Key0xB"))
        #expect(message == reversedMessage)
        #expect(!message.contains("unknown context at"))
        #expect(!message.contains("$"))
    }

    @Test("Same-named function-local diagnostic keys both render deterministically")
    func sameNamedLocalContextKeysBothRender() throws {
        let requestID = try RequestID(rawValue: #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000021"),
        ))
        let first = settingFirstSameNamedLocalDiagnosticKey(in: RequestContext())
        let forward = settingSecondSameNamedLocalDiagnosticKey(in: first.context)
        let second = settingSecondSameNamedLocalDiagnosticKey(in: RequestContext())
        let reverse = settingFirstSameNamedLocalDiagnosticKey(in: second.context)
        let representation = forward.context.diagnosticRepresentation
        let reverseRepresentation = reverse.context.diagnosticRepresentation
        let message = diagnosticMessage(for: forward.context, requestID: requestID)
        let reverseMessage = diagnosticMessage(for: reverse.context, requestID: requestID)

        #expect(first.diagnosticName == forward.diagnosticName)
        #expect(representation.count == 2)
        #expect(Set(representation.map(\.key)).count == 1)
        #expect(Set(representation.map(\.value)) == [
            "first-local=FIRST-LOCAL-DIAGNOSTIC-VALUE",
            "second-local=SECOND-LOCAL-DIAGNOSTIC-VALUE",
        ])
        #expect(representation == reverseRepresentation)
        #expect(message.contains("FIRST-LOCAL-DIAGNOSTIC-VALUE"))
        #expect(message.contains("SECOND-LOCAL-DIAGNOSTIC-VALUE"))
        #expect(message.components(separatedBy: "\(first.diagnosticName)=").count - 1 == 2)
        #expect(message == reverseMessage)
        #expect(!message.contains("unknown context at"))
        #expect(!message.contains("$"))
        #expect(!message.contains("0x"))
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

enum DiagnosticLabelKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "label=\(value)"
    }
}

private func diagnosticMessage(for context: RequestContext, requestID: RequestID) -> String {
    let event = NetworkEvent.requestStarted(RequestStartedEvent(
        requestID: requestID,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        requestContext: context,
    ))
    return NetworkLoggerFormatter(configuration: .init()).format(event).message
}

private func settingFirstSameNamedLocalDiagnosticKey(
    in context: RequestContext,
) -> (context: RequestContext, diagnosticName: String) {
    struct SharedLocalDiagnosticKey: DiagnosticRequestContextKey {
        typealias Value = String

        static func diagnosticDescription(for value: String) -> String {
            "first-local=\(value)"
        }
    }

    return (
        context.setting(SharedLocalDiagnosticKey.self, value: "FIRST-LOCAL-DIAGNOSTIC-VALUE"),
        NetworkDiagnosticTypeName.contextKeyName(for: SharedLocalDiagnosticKey.self),
    )
}

private func settingSecondSameNamedLocalDiagnosticKey(
    in context: RequestContext,
) -> (context: RequestContext, diagnosticName: String) {
    struct SharedLocalDiagnosticKey: DiagnosticRequestContextKey {
        typealias Value = String

        static func diagnosticDescription(for value: String) -> String {
            "second-local=\(value)"
        }
    }

    return (
        context.setting(SharedLocalDiagnosticKey.self, value: "SECOND-LOCAL-DIAGNOSTIC-VALUE"),
        NetworkDiagnosticTypeName.contextKeyName(for: SharedLocalDiagnosticKey.self),
    )
}

private struct DiagnosticArgumentBox<Argument: Sendable>: Sendable {}

private struct Key0xA: Sendable {}

private struct Key0xB: Sendable {}

private enum GenericDiagnosticContextKey<Argument: Sendable>: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "value=\(value)"
    }
}

// swiftlint:disable type_name
private enum Diagnostic🐶ContextKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "value=\(value)"
    }
}

private enum Diagnostic🐱ContextKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "value=\(value)"
    }
}

// swiftlint:enable type_name
