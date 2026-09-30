//
//  RequestContext.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// One opted-in context value paired with its privacy-safe diagnostic key name.
package struct RequestContextDiagnosticEntry: Sendable, Equatable {
    package let key: String
    package let value: String
}

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

    /// Compares a stored typed value using its already-resolved key identifier.
    ///
    /// - Parameters:
    ///   - expected: The value to compare with the stored context value.
    ///   - keyIdentifier: The identity of the context key that owns the value.
    package func matches<Value: Sendable & Equatable>(
        _ expected: Value,
        forKeyIdentifier keyIdentifier: ObjectIdentifier,
    ) -> Bool {
        guard let value = entries[keyIdentifier]?.value as? Value else {
            return false
        }

        return value == expected
    }

    /// Returns opted-in values with normalized key names, retaining keys whose safe names collide.
    package var diagnosticRepresentation: [RequestContextDiagnosticEntry] {
        entries.values
            .compactMap { entry in
                guard let key = entry.diagnosticKey, let value = entry.diagnosticValue else {
                    return nil
                }

                return RequestContextDiagnosticEntry(key: key, value: value)
            }
            .sorted { left, right in
                left.key == right.key ? left.value < right.value : left.key < right.key
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
            diagnosticKey: diagnosticValue.map { _ in
                NetworkDiagnosticTypeName.contextKeyName(for: Key.self)
            },
            diagnosticValue: diagnosticValue,
        )
        return Self(entries: updatedEntries)
    }
}
