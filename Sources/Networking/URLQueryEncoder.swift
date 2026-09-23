//
//  URLQueryEncoder.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Describes a value that cannot be represented by the limited query encoder.
public enum URLQueryEncodingError: Error, Sendable, Equatable {
    /// The top-level value did not provide keyed query fields.
    case topLevelContainerUnsupported

    /// A keyed container was encountered below the top-level query container.
    case nestedKeyedContainer(codingPath: [String])

    /// An unkeyed container was encountered below an array query field.
    case nestedUnkeyedContainer(codingPath: [String])
}

/// Encodes a limited Codable value into ordered URL query items.
public struct URLQueryEncoder: Sendable {
    /// Controls how array values are represented in the query.
    public enum ArrayStrategy: Sendable {
        /// Emits one query item with the same key for each element.
        case repeatedKey

        /// Emits one query item with a [] suffix for each element.
        case brackets
    }

    /// Controls how Boolean values are represented in the query.
    public enum BoolStrategy: Sendable {
        /// Emits true and false.
        case literal

        /// Emits 1 and 0.
        case numeric
    }

    /// Controls how dates are represented in the query.
    public enum DateStrategy: Sendable {
        /// Emits an ISO-8601 date string.
        case iso8601

        /// Emits seconds since January 1, 1970.
        case secondsSince1970

        /// Emits milliseconds since January 1, 1970.
        case millisecondsSince1970

        /// Emits the value returned by the supplied Sendable formatter.
        case custom(@Sendable (Date) -> String)
    }

    /// Stores optional strategy overrides for one encoder layer.
    public struct Configuration: Sendable {
        /// The array representation override, or nil to use the encoder default.
        public let arrayStrategy: ArrayStrategy?

        /// The Boolean representation override, or nil to use the encoder default.
        public let boolStrategy: BoolStrategy?

        /// The date representation override, or nil to use the encoder default.
        public let dateStrategy: DateStrategy?

        /// Creates query encoder strategy overrides.
        ///
        /// A missing strategy uses the 1.0 default: repeated keys for arrays, literal values for
        /// Booleans, and ISO-8601 values for dates.
        public init(
            arrayStrategy: ArrayStrategy? = nil,
            boolStrategy: BoolStrategy? = nil,
            dateStrategy: DateStrategy? = nil,
        ) {
            self.arrayStrategy = arrayStrategy
            self.boolStrategy = boolStrategy
            self.dateStrategy = dateStrategy
        }

        package func applying(_ overrides: Self) -> Self {
            Self(
                arrayStrategy: overrides.arrayStrategy ?? arrayStrategy,
                boolStrategy: overrides.boolStrategy ?? boolStrategy,
                dateStrategy: overrides.dateStrategy ?? dateStrategy,
            )
        }
    }

    private let configuration: Configuration

    /// Creates an encoder with the supplied strategy overrides.
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Encodes a keyed Codable value into deterministic query items.
    ///
    /// Top-level keys are sorted lexically. Array elements retain their source order, and nil
    /// optional values are omitted. Nested keyed containers are intentionally unsupported.
    ///
    /// - Parameter value: The keyed Codable value to encode.
    /// - Returns: Query items ordered by encoded key and then source array order.
    /// - Throws: URLQueryEncodingError when the value uses an unsupported container shape.
    public func encode(_ value: some Encodable) throws -> [URLQueryItem] {
        let storage = QueryStorage()
        let encoder = QueryEncoder(
            storage: storage,
            configuration: configuration,
            codingPath: [],
            emit: nil,
            allowsUnkeyedContainer: false,
        )
        try value.encode(to: encoder)

        return storage.values.keys.sorted().flatMap { key in
            storage.values[key, default: []].map { value in
                URLQueryItem(name: key, value: value)
            }
        }
    }

    private var arrayStrategy: ArrayStrategy {
        configuration.arrayStrategy ?? .repeatedKey
    }

    private var boolStrategy: BoolStrategy {
        configuration.boolStrategy ?? .literal
    }

    private var dateStrategy: DateStrategy {
        configuration.dateStrategy ?? .iso8601
    }

    private func scalarString(_ value: some Encodable) -> String? {
        if let stringValue = value as? String {
            return stringValue
        }
        if let boolValue = value as? Bool {
            switch boolStrategy {
            case .literal:
                return boolValue ? "true" : "false"
            case .numeric:
                return boolValue ? "1" : "0"
            }
        }
        if let dateValue = value as? Date {
            switch dateStrategy {
            case .iso8601:
                return ISO8601DateFormatter().string(from: dateValue)
            case .secondsSince1970:
                return String(dateValue.timeIntervalSince1970)
            case .millisecondsSince1970:
                return String(dateValue.timeIntervalSince1970 * 1_000)
            case let .custom(format):
                return format(dateValue)
            }
        }
        return integerString(value) ?? floatingPointString(value)
    }

    private func integerString(_ value: some Encodable) -> String? {
        if let intValue = value as? Int {
            return String(intValue)
        }
        if let int8Value = value as? Int8 {
            return String(int8Value)
        }
        if let int16Value = value as? Int16 {
            return String(int16Value)
        }
        if let int32Value = value as? Int32 {
            return String(int32Value)
        }
        if let int64Value = value as? Int64 {
            return String(int64Value)
        }
        if let uintValue = value as? UInt {
            return String(uintValue)
        }
        if let uint8Value = value as? UInt8 {
            return String(uint8Value)
        }
        if let uint16Value = value as? UInt16 {
            return String(uint16Value)
        }
        if let uint32Value = value as? UInt32 {
            return String(uint32Value)
        }
        if let uint64Value = value as? UInt64 {
            return String(uint64Value)
        }
        return nil
    }

    private func floatingPointString(_ value: some Encodable) -> String? {
        if let floatValue = value as? Float {
            return String(floatValue)
        }
        if let doubleValue = value as? Double {
            return String(doubleValue)
        }
        return nil
    }

    private final class QueryStorage {
        var values: [String: [String]] = [:]

        func append(_ value: String, for key: String) {
            values[key, default: []].append(value)
        }
    }

    private struct QueryEncoder: Encoder {
        let storage: QueryStorage
        let configuration: Configuration
        let codingPath: [any CodingKey]
        let emit: ((String) -> Void)?
        let allowsUnkeyedContainer: Bool
        var userInfo: [CodingUserInfoKey: Any] {
            [:]
        }

        func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
            let failure: URLQueryEncodingError? =
                if emit == nil {
                    nil
                } else {
                    .nestedKeyedContainer(codingPath: codingPath.map(\.stringValue))
                }
            return KeyedEncodingContainer(
                QueryKeyedEncodingContainer(
                    encoder: self,
                    failure: failure,
                ),
            )
        }

        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            let failure: URLQueryEncodingError? =
                if emit == nil {
                    .topLevelContainerUnsupported
                } else if !allowsUnkeyedContainer {
                    .nestedUnkeyedContainer(codingPath: codingPath.map(\.stringValue))
                } else {
                    nil
                }
            return QueryUnkeyedEncodingContainer(
                encoder: self,
                failure: failure,
            )
        }

        func singleValueContainer() -> any SingleValueEncodingContainer {
            QuerySingleValueEncodingContainer(
                codingPath: codingPath,
                emit: emit,
                failure: emit == nil ? .topLevelContainerUnsupported : nil,
                scalarString: { value in
                    URLQueryEncoder(configuration: configuration).scalarString(value)
                },
            )
        }

        func child(for key: String, codingPath: [any CodingKey]) -> Self {
            Self(
                storage: storage,
                configuration: configuration,
                codingPath: codingPath,
                emit: { value in storage.append(value, for: key) },
                allowsUnkeyedContainer: true,
            )
        }

        func childForArrayElement(codingPath: [any CodingKey], key: String) -> Self {
            Self(
                storage: storage,
                configuration: configuration,
                codingPath: codingPath,
                emit: { value in storage.append(value, for: key) },
                allowsUnkeyedContainer: false,
            )
        }
    }

    private struct QueryKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let encoder: QueryEncoder
        let failure: URLQueryEncodingError?

        var codingPath: [any CodingKey] {
            encoder.codingPath
        }

        mutating func encodeNil(forKey _: Key) throws {
            try failIfNeeded()
        }

        mutating func encode(_ value: some Encodable, forKey key: Key) throws {
            try failIfNeeded()
            if let scalar = URLQueryEncoder(configuration: encoder.configuration).scalarString(value) {
                encoder.storage.append(scalar, for: key.stringValue)
                return
            }
            let child = encoder.child(for: key.stringValue, codingPath: codingPath + [key])
            try value.encode(to: child)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy _: NestedKey.Type,
            forKey key: Key,
        ) -> KeyedEncodingContainer<NestedKey> {
            let nestedFailure = failure ?? .nestedKeyedContainer(
                codingPath: (codingPath + [key]).map(\.stringValue),
            )
            return KeyedEncodingContainer(
                QueryKeyedEncodingContainer<NestedKey>(
                    encoder: encoder,
                    failure: nestedFailure,
                ),
            )
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            QueryUnkeyedEncodingContainer(
                encoder: encoder.child(for: key.stringValue, codingPath: codingPath + [key]),
                failure: failure,
            )
        }

        mutating func superEncoder() -> any Encoder {
            encoder
        }

        mutating func superEncoder(forKey key: Key) -> any Encoder {
            encoder.child(for: key.stringValue, codingPath: codingPath + [key])
        }

        private func failIfNeeded() throws {
            if let failure {
                throw failure
            }
        }
    }

    private struct QueryUnkeyedEncodingContainer: UnkeyedEncodingContainer {
        let encoder: QueryEncoder
        let failure: URLQueryEncodingError?
        var count = 0

        var codingPath: [any CodingKey] {
            encoder.codingPath
        }

        mutating func encodeNil() throws {
            try failIfNeeded()
            count += 1
        }

        mutating func encode(_ value: some Encodable) throws {
            try failIfNeeded()
            let key = codingPath.last?.stringValue ?? ""
            let outputKey: String =
                switch URLQueryEncoder(configuration: encoder.configuration).arrayStrategy {
                case .repeatedKey:
                    key
                case .brackets:
                    "\(key)[]"
                }
            if let scalar = URLQueryEncoder(configuration: encoder.configuration).scalarString(value) {
                encoder.storage.append(scalar, for: outputKey)
                count += 1
                return
            }

            let child = encoder.childForArrayElement(
                codingPath: codingPath + [ArrayIndexKey(index: count)],
                key: outputKey,
            )
            try value.encode(to: child)
            count += 1
        }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy _: NestedKey.Type,
        ) -> KeyedEncodingContainer<NestedKey> {
            let nestedFailure = failure ?? .nestedKeyedContainer(
                codingPath: (codingPath + [ArrayIndexKey(index: count)]).map(\.stringValue),
            )
            count += 1
            return KeyedEncodingContainer(
                QueryKeyedEncodingContainer<NestedKey>(
                    encoder: encoder,
                    failure: nestedFailure,
                ),
            )
        }

        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            let nestedFailure = failure ?? .nestedUnkeyedContainer(
                codingPath: (codingPath + [ArrayIndexKey(index: count)]).map(\.stringValue),
            )
            count += 1
            return QueryUnkeyedEncodingContainer(encoder: encoder, failure: nestedFailure)
        }

        mutating func superEncoder() -> any Encoder {
            encoder
        }

        private func failIfNeeded() throws {
            if let failure {
                throw failure
            }
        }
    }

    private struct QuerySingleValueEncodingContainer: SingleValueEncodingContainer {
        let codingPath: [any CodingKey]
        let emit: ((String) -> Void)?
        let failure: URLQueryEncodingError?
        let scalarString: (any Encodable) -> String?

        mutating func encodeNil() throws {
            try failIfNeeded()
        }

        mutating func encode(_ value: some Encodable) throws {
            try failIfNeeded()
            guard let emit, let scalar = scalarString(value) else {
                throw URLQueryEncodingError.topLevelContainerUnsupported
            }

            emit(scalar)
        }

        private func failIfNeeded() throws {
            if let failure {
                throw failure
            }
        }
    }

    private struct ArrayIndexKey: CodingKey {
        let intValue: Int?
        let stringValue: String

        init(index: Int) {
            intValue = index
            stringValue = "[\(index)]"
        }

        init?(stringValue: String) {
            intValue = nil
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.init(index: intValue)
        }
    }
}
