//
//  RequestContext.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Identifies a typed value that can be carried with a request.
public protocol RequestContextKey<Value> {
    /// The Sendable value stored for this key.
    associatedtype Value: Sendable
}

/// Identifies a request context key whose value may appear in diagnostic output.
public protocol DiagnosticRequestContextKey<Value>: RequestContextKey {
    /// Creates the diagnostic representation of a value stored for this key.
    ///
    /// - Parameter value: The value associated with the key.
    /// - Returns: A string selected by the key's owner for diagnostic output.
    static func diagnosticDescription(for value: Value) -> String
}

/// Stores typed, optional request metadata without providing default values.
public struct RequestContext: Sendable {
    private struct Entry: Sendable {
        let value: any Sendable
        let diagnosticKey: String?
        let diagnosticValue: String?
    }

    private let entries: [ObjectIdentifier: Entry]

    /// Creates an empty request context.
    public init() {
        entries = [:]
    }

    private init(entries: [ObjectIdentifier: Entry]) {
        self.entries = entries
    }

    /// Returns the value stored for `Key`, or `nil` when that key is unset.
    public subscript<Key: RequestContextKey>(_ key: Key.Type) -> Key.Value? {
        entries[ObjectIdentifier(key)]?.value as? Key.Value
    }

    /// Returns diagnostic values recorded for keys that explicitly opt in.
    ///
    /// The dictionary key is the fully qualified Swift type name of the context key.
    package var diagnosticRepresentation: [String: String] {
        entries.values.reduce(into: [:]) { result, entry in
            guard let key = entry.diagnosticKey, let value = entry.diagnosticValue else {
                return
            }

            result[key] = value
        }
    }

    package func setting<Key: RequestContextKey>(
        _ key: Key.Type,
        value: Key.Value,
    ) -> Self {
        let keyIdentifier = ObjectIdentifier(key)
        let diagnosticValue: String? =
            if let diagnosticKey = key as? any DiagnosticRequestContextKey<Key.Value>.Type {
                diagnosticKey.diagnosticDescription(for: value)
            } else {
                nil
            }

        var updatedEntries = entries
        updatedEntries[keyIdentifier] = Entry(
            value: value,
            diagnosticKey: diagnosticValue.map { _ in String(reflecting: Key.self) },
            diagnosticValue: diagnosticValue,
        )
        return Self(entries: updatedEntries)
    }
}
