//
//  URLQueryEncoderTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import SnapshotTesting
import Testing
@testable import Networking

@Suite(.serialized, .snapshots(record: .missing))
struct URLQueryEncoderTests {
    @Test
    func defaultEncodingSnapshot() throws {
        let values = DefaultQueryValues(
            zulu: "last",
            omitted: nil,
            empty: "",
            enabled: true,
            timestamp: Date(timeIntervalSince1970: 1_234.5),
            values: [2, 1],
        )

        let encoded = try URLQueryEncoder().encode(values)

        #expect(rendered(encoded).contains("timestamp=1970-01-01T00:20:34Z"))
        assertSnapshot(of: rendered(encoded), as: .lines)
    }

    @Test
    func configuredEncodingSnapshot() throws {
        let values = ConfiguredQueryValues(
            enabled: true,
            timestamp: Date(timeIntervalSince1970: 1_234.5),
            values: ["one", "two"],
        )
        let configuration = URLQueryEncoder.Configuration(
            arrayStrategy: .brackets,
            boolStrategy: .numeric,
            dateStrategy: .custom { date in
                String(Int(date.timeIntervalSince1970))
            },
        )

        let encoded = try URLQueryEncoder(configuration: configuration).encode(values)

        assertSnapshot(of: rendered(encoded), as: .lines)
    }

    @Test
    func dateStrategiesSnapshot() throws {
        let values = DateQueryValues(timestamp: Date(timeIntervalSince1970: 1_234.5))
        let configurations: [(String, URLQueryEncoder.Configuration)] = [
            ("iso8601", .init(dateStrategy: .iso8601)),
            ("seconds", .init(dateStrategy: .secondsSince1970)),
            ("milliseconds", .init(dateStrategy: .millisecondsSince1970)),
        ]
        let outputs = try configurations.map { name, configuration in
            let encoded = try URLQueryEncoder(configuration: configuration).encode(values)
            return name + "\n" + rendered(encoded)
        }

        assertSnapshot(of: outputs, as: .json)
    }

    @Test
    func singleValueArrayElementsUseArrayStrategy() throws {
        let values = SingleValueArrayQuery(values: [.first, .second])
        let bracketed = try URLQueryEncoder(
            configuration: .init(arrayStrategy: .brackets),
        ).encode(values)
        let repeated = try URLQueryEncoder(
            configuration: .init(arrayStrategy: .repeatedKey),
        ).encode(values)

        #expect(rendered(bracketed) == "values[]=first\nvalues[]=second")
        #expect(rendered(repeated) == "values=first\nvalues=second")
        assertSnapshot(
            of: [
                "brackets\n" + rendered(bracketed),
                "repeatedKey\n" + rendered(repeated),
            ],
            as: .json,
        )
    }

    @Test
    func nestedKeyedContainerFailsPrecisely() {
        let values = NestedQueryValues(child: NestedChild(value: "value"))

        do {
            _ = try URLQueryEncoder().encode(values)
            Issue.record("Expected nested keyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .nestedKeyedContainer(codingPath: ["child"]))
        } catch {
            Issue.record("Unexpected query encoding error: \(error)")
        }
    }

    @Test
    func unsupportedContainerShapesFailPrecisely() {
        do {
            _ = try URLQueryEncoder().encode(["value"])
            Issue.record("Expected a top-level unkeyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .topLevelContainerUnsupported)
        } catch {
            Issue.record("Unexpected top-level query encoding error: \(error)")
        }

        do {
            _ = try URLQueryEncoder().encode(NestedArrayQuery(values: [["value"]]))
            Issue.record("Expected a nested unkeyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .nestedUnkeyedContainer(codingPath: ["values", "[0]"]))
        } catch {
            Issue.record("Unexpected nested query encoding error: \(error)")
        }
    }

    @Test
    func emptyTopLevelUnkeyedContainerFails() {
        do {
            _ = try URLQueryEncoder().encode([String]())
            Issue.record("Expected an empty top-level unkeyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .topLevelContainerUnsupported)
        } catch {
            Issue.record("Unexpected top-level query encoding error: \(error)")
        }
    }

    @Test
    func emptyNestedKeyedContainerFailsPrecisely() {
        do {
            _ = try URLQueryEncoder().encode(EmptyNestedKeyedQuery(child: EmptyNestedChild()))
            Issue.record("Expected an empty nested keyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .nestedKeyedContainer(codingPath: ["child"]))
        } catch {
            Issue.record("Unexpected nested keyed query encoding error: \(error)")
        }
    }

    @Test
    func emptyNestedUnkeyedContainerFailsPrecisely() {
        do {
            _ = try URLQueryEncoder().encode(EmptyNestedArrayQuery(values: [[]]))
            Issue.record("Expected an empty nested unkeyed query encoding to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .nestedUnkeyedContainer(codingPath: ["values", "[0]"]))
        } catch {
            Issue.record("Unexpected nested unkeyed query encoding error: \(error)")
        }
    }

    @Test
    func emptyFirstLevelArrayFieldIsOmittedWithoutError() throws {
        let encoded = try URLQueryEncoder().encode(EmptyFirstLevelArrayQuery(values: []))

        #expect(encoded.isEmpty)
    }

    @Test
    func unorderedSetFailsWithItsCodingPath() {
        do {
            _ = try URLQueryEncoder().encode(UnorderedSetQuery(values: ["alpha", "beta"]))
            Issue.record("Expected an unordered Set query value to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values"]))
        } catch {
            Issue.record("Unexpected unordered collection error: \(error)")
        }
    }

    @Test
    func optionalUnorderedSetFailsWithItsCodingPath() {
        do {
            _ = try URLQueryEncoder().encode(
                OptionalUnorderedSetQuery(values: Set(["alpha", "beta"])),
            )
            Issue.record("Expected an Optional-wrapped unordered Set query value to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values"]))
        } catch {
            Issue.record("Unexpected unordered collection error: \(error)")
        }
    }

    @Test
    func optionalUnorderedDictionaryFailsWithItsCodingPath() {
        do {
            _ = try URLQueryEncoder().encode(
                OptionalUnorderedDictionaryQuery(values: [true: "enabled", false: "disabled"]),
            )
            Issue.record("Expected an Optional-wrapped unordered Dictionary query value to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values"]))
        } catch {
            Issue.record("Unexpected unordered collection error: \(error)")
        }
    }

    @Test
    func unorderedDictionaryUsingUnkeyedCodableFormFailsWithItsCodingPath() {
        do {
            _ = try URLQueryEncoder().encode(
                UnorderedDictionaryQuery(values: [true: "enabled", false: "disabled"]),
            )
            Issue.record("Expected an unordered Dictionary query value to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values"]))
        } catch {
            Issue.record("Unexpected unordered collection error: \(error)")
        }
    }

    @Test
    func catchingUnorderedKeyedEncodingErrorDoesNotAllowPartialQuery() {
        do {
            _ = try URLQueryEncoder().encode(CatchingUnorderedKeyedQuery())
            Issue.record("Expected a caught unordered query error to remain authoritative")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values"]))
        } catch {
            Issue.record("Unexpected unordered collection error: \(error)")
        }
    }

    @Test
    func catchingUnorderedArrayElementErrorDoesNotAllowPartialQuery() {
        do {
            _ = try URLQueryEncoder().encode(CatchingUnorderedArrayElementQuery())
            Issue.record("Expected a caught unordered array element error to remain authoritative")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unorderedCollection(codingPath: ["values", "[0]"]))
        } catch {
            Issue.record("Unexpected unordered array element error: \(error)")
        }
    }

    @Test
    func catchingUnsupportedSingleValueErrorDoesNotAllowPartialQuery() {
        do {
            _ = try URLQueryEncoder().encode(CatchingUnsupportedSingleValueQuery())
            Issue.record("Expected a caught unsupported scalar error to remain authoritative")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unsupportedSingleValue(codingPath: ["value"]))
        } catch {
            Issue.record("Unexpected unsupported scalar error: \(error)")
        }
    }

    @Test
    func codingKeyRepresentableDictionaryUsesLexicallyOrderedQueryKeys() throws {
        let values: [QueryDictionaryKey: String] = [
            .zulu: "last",
            .alpha: "first",
        ]

        let encoded = try URLQueryEncoder().encode(values)

        #expect(encoded.map(\.name) == ["alpha", "zulu"])
        #expect(rendered(encoded) == "alpha=first\nzulu=last")
    }

    @Test
    func nestedUnsupportedSingleValueFailsAtItsCodingPath() {
        do {
            _ = try URLQueryEncoder().encode(
                UnsupportedSingleValueQuery(value: UnsupportedSingleValue()),
            )
            Issue.record("Expected an unsupported nested single value to fail")
        } catch let error as URLQueryEncodingError {
            #expect(error == .unsupportedSingleValue(codingPath: ["value"]))
        } catch {
            Issue.record("Unexpected single-value query encoding error: \(error)")
        }
    }
}

private struct DefaultQueryValues: Encodable, Sendable {
    let zulu: String
    let omitted: String?
    let empty: String
    let enabled: Bool
    let timestamp: Date
    let values: [Int]
}

private struct ConfiguredQueryValues: Encodable, Sendable {
    let enabled: Bool
    let timestamp: Date
    let values: [String]
}

private struct DateQueryValues: Encodable, Sendable {
    let timestamp: Date
}

private struct SingleValueArrayQuery: Encodable, Sendable {
    let values: [QueryTag]
}

private enum QueryTag: String, Encodable, Sendable {
    case first
    case second
}

private struct NestedQueryValues: Encodable, Sendable {
    let child: NestedChild
}

private struct NestedChild: Encodable, Sendable {
    let value: String
}

private struct NestedArrayQuery: Encodable, Sendable {
    let values: [[String]]
}

private struct EmptyNestedKeyedQuery: Encodable, Sendable {
    let child: EmptyNestedChild
}

private struct EmptyNestedChild: Encodable, Sendable {}

private struct EmptyNestedArrayQuery: Encodable, Sendable {
    let values: [[String]]
}

private struct EmptyFirstLevelArrayQuery: Encodable, Sendable {
    let values: [String]
}

private struct UnorderedSetQuery: Encodable, Sendable {
    let values: Set<String>
}

private struct OptionalUnorderedSetQuery: Encodable, Sendable {
    let values: Set<String>?
}

private struct OptionalUnorderedDictionaryQuery: Encodable, Sendable {
    let values: [Bool: String]?
}

private struct UnorderedDictionaryQuery: Encodable, Sendable {
    let values: [Bool: String]
}

private struct CatchingUnorderedKeyedQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case values
        case survivor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        do {
            try container.encode(Set(["alpha", "beta"]), forKey: .values)
        } catch {}
        try container.encode("present", forKey: .survivor)
    }
}

private struct CatchingUnorderedArrayElementQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case values
        case survivor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var values = container.nestedUnkeyedContainer(forKey: .values)
        do {
            try values.encode(Set(["alpha", "beta"]))
        } catch {}
        try container.encode("present", forKey: .survivor)
    }
}

private enum QueryDictionaryKey: String, Encodable, CodingKeyRepresentable {
    case alpha
    case zulu
}

private struct CatchingUnsupportedSingleValueQuery: Encodable {
    private enum CodingKeys: String, CodingKey {
        case value
        case survivor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        do {
            try container.encode(UnsupportedSingleValue(), forKey: .value)
        } catch {}
        try container.encode("present", forKey: .survivor)
    }
}

private struct UnsupportedSingleValueQuery: Encodable {
    let value: UnsupportedSingleValue
}

private struct UnsupportedSingleValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(UnsupportedContainerValue())
    }
}

private struct UnsupportedContainerValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode("not a supported query scalar")
    }
}

private func rendered(_ items: [URLQueryItem]) -> String {
    items.lazy
        .map { item in
            guard let value = item.value else {
                return item.name
            }

            return "\(item.name)=\(value)"
        }
        .joined(separator: "\n")
}
