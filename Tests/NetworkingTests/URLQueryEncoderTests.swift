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
            values: [2, 1],
        )

        let encoded = try URLQueryEncoder().encode(values)

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
}

private struct DefaultQueryValues: Encodable, Sendable {
    let zulu: String
    let omitted: String?
    let empty: String
    let enabled: Bool
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
