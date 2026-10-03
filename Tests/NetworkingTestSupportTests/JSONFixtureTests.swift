//
//  JSONFixtureTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Testing
@testable import NetworkingTestSupport

private struct FixtureModel: Codable, Equatable {
    let id: Int
    let createdAt: Date
}

private struct SampleFixture: Decodable, Equatable {
    let name: String
    let items: [Int]
}

@Test("Inline fixtures keep their original bytes and validate their content")
func jsonFixtureAcceptsInlineTextAndData() throws {
    let text = #"{"b":[2,3],"a":{"n":1}}"#
    let fixture = try JSONFixture(json: text)

    #expect(fixture.data == Data(text.utf8))
    #expect(try JSONFixture(data: Data(text.utf8)).data == fixture.data)
}

@Test("Invalid JSON is rejected with the shared semantic JSON error")
func jsonFixtureRejectsMalformedJSON() throws {
    _ = try JSONFixture(json: #"{"a":1}"#)

    #expect(throws: RequestMatcherError.invalidJSON) {
        try JSONFixture(json: "{")
    }
    #expect(throws: RequestMatcherError.invalidJSON) {
        try JSONFixture(json: #"{"a":1-2}"#)
    }
    #expect(throws: RequestMatcherError.invalidJSON) {
        try JSONFixture(data: Data())
    }
}

@Test("Fixture encoding and decoding use caller-configured codecs")
func jsonFixtureEncodingAndDecodingUseConfiguredCodecs() throws {
    let model = FixtureModel(id: 7, createdAt: Date(timeIntervalSince1970: 1_000_000))
    let fixture = try JSONFixture(encoding: model) { encoder in
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    let decoded = try fixture.decode(FixtureModel.self) { decoder in
        decoder.dateDecodingStrategy = .iso8601
    }

    #expect(decoded == model)
    #expect(throws: DecodingError.self) {
        try fixture.decode(FixtureModel.self)
    }
}

@Test("Fixture resources load from the caller-supplied bundle and report missing resources")
func jsonFixtureResourcesRequireAnExplicitBundle() throws {
    let fixture = try JSONFixture.resource(named: "sample.json", in: .module, subdirectory: "Fixtures")
    #expect(try fixture.decode(SampleFixture.self) == SampleFixture(name: "fixture", items: [1, 2, 3]))

    do {
        _ = try JSONFixture.resource(named: "missing.json", in: .module, subdirectory: "Fixtures")
        Issue.record("Expected the missing resource to fail.")
    } catch let error as JSONFixture.LoadingError {
        let description = try #require(error.errorDescription)
        #expect(description.contains("missing.json"))
        #expect(description.contains("Fixtures"))
        #expect(description.contains(Bundle.module.bundlePath))
    }
}

@Test("JSON stubs default to 200 OK with a JSON content type and honor overrides")
func jsonStubResponsesDefaultToJSONContentType() throws {
    let fixture = try JSONFixture(json: #"{"ok":true}"#)

    guard case let .httpResponse(data, response) = fixture.httpStubResponse() else {
        Issue.record("Expected an in-memory HTTP stub response.")
        return
    }

    #expect(data == fixture.data)
    #expect(response.status.code == 200)
    #expect(response.headerFields[.contentType] == "application/json")

    guard case let .download(downloadData, downloadResponse) = fixture.downloadStubResponse(
        status: .init(code: 201),
        headers: [.contentType: "application/vnd.api+json"],
    ) else {
        Issue.record("Expected a download stub response.")
        return
    }

    #expect(downloadData == fixture.data)
    #expect(downloadResponse.status.code == 201)
    #expect(downloadResponse.headerFields[.contentType] == "application/vnd.api+json")
}

@Test("Fixture matchers reuse the semantic JSON equality model")
func jsonFixtureMatcherReusesSemanticJSONEquality() throws {
    let fixture = try JSONFixture(json: #"{"a":0.10000000000000000000000000001,"b":[1,2]}"#)
    let matcher = fixture.requestMatcher()

    #expect(matcher.mismatch(for: jsonBodyRecorded(#"{"b":[1,2],"a":0.10000000000000000000000000001}"#)) == nil)
    #expect(matcher.mismatch(for: jsonBodyRecorded(#"{"b":[1,2],"a":0.1}"#)) == .semanticJSONBody)
    #expect(matcher
        .mismatch(for: jsonBodyRecorded(#"{"b":[2,1],"a":0.10000000000000000000000000001}"#)) == .semanticJSONBody)
}

@Test("Canonical rendering sorts keys, keeps array order, and preserves number spellings")
func jsonFixtureCanonicalRenderingIsDeterministic() throws {
    let source = #"{"z":1e400,"list":[3,1,2],"a":0.10000000000000000000000000001}"#
    let canonical = try JSONFixture(json: source).canonicalJSON

    #expect(try canonical == (JSONFixture(json: source).canonicalJSON))
    #expect(try canonical ==
        (JSONFixture(json: #"{"a":0.10000000000000000000000000001,"z":1e400,"list":[3,1,2]}"#).canonicalJSON))
    #expect(canonical.contains("1e400"))
    #expect(canonical.contains("0.10000000000000000000000000001"))

    let aIndex = try #require(canonical.range(of: #""a""#))
    let zIndex = try #require(canonical.range(of: #""z""#))
    #expect(aIndex.lowerBound < zIndex.lowerBound)

    let listIndex = try #require(canonical.range(of: #""list""#))
    let listSection = canonical[listIndex.upperBound...]
    let threeIndex = try #require(listSection.range(of: "3"))
    let oneIndex = try #require(listSection.range(of: "1"))
    #expect(threeIndex.lowerBound < oneIndex.lowerBound)
}

private func jsonBodyRecorded(_ body: String) -> RecordedRequest {
    RecordedRequest(
        httpRequest: HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/upload"),
        preparedBody: .data(Data(body.utf8)),
        requestID: RequestID(rawValue: UUID()),
        attemptNumber: 1,
        requestContext: RequestContext(),
    )
}
