//
//  SnapshotStrategyTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import NetworkingTestSupport
import SnapshotTesting
import Testing

private struct SamplePayload: Sendable {
    let name: String
    let count: Int
}

private struct SecretBearingError: Error, CustomStringConvertible {
    var description: String {
        "failed at https://private.example/token with secret-value"
    }
}

/// A context key whose value opts in to diagnostic output.
enum SnapshotDiagnosticLabelKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        "snapshot-label=\(value)"
    }
}

/// An ordinary context key whose value must never reach snapshot output.
enum SnapshotPrivateTokenKey: RequestContextKey {
    typealias Value = String
}

@Test("Snapshot context projections include diagnostic keys and omit ordinary values")
func snapshotContextProjectionsAreDiagnosticOnly() async {
    let context = RequestContext()
        .setting(SnapshotDiagnosticLabelKey.self, value: "visible")
        .setting(SnapshotPrivateTokenKey.self, value: "must-not-appear")
    let recorded = RecordedRequest(
        httpRequest: HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource"),
        preparedBody: .none,
        requestID: RequestID(rawValue: UUID()),
        attemptNumber: 1,
        requestContext: context,
    )

    for output in await [
        rendered(.recordedRequest, recorded),
        rendered(.recordedRequest(.exact), recorded),
    ] {
        #expect(output.contains("snapshot-label=visible"))
        #expect(!output.contains("must-not-appear"))
        #expect(output.contains("body: .none"))
    }
}

@Test("Recorded request snapshots stay stable, redacted, and metadata-only for file bodies")
func recordedRequestSnapshotsAreStableAndRedacted() async throws {
    let request = HTTPRequest(
        method: .post,
        scheme: "https",
        authority: "example.com",
        path: "/upload?token=secret-query&page=2",
        headerFields: [
            .authorization: "Bearer secret-token",
            .cookie: "session=secret-cookie",
            .accept: "application/json",
        ],
    )
    let firstFile = try makeTemporaryBodyFile(contents: "file-backed-secret")
    let secondFile = try makeTemporaryBodyFile(contents: "file-backed-secret")
    defer {
        try? FileManager.default.removeItem(at: firstFile)
        try? FileManager.default.removeItem(at: secondFile)
    }

    let first = RecordedRequest(
        httpRequest: request,
        preparedBody: .file(firstFile),
        requestID: RequestID(rawValue: UUID()),
        attemptNumber: 1,
        requestContext: RequestContext(),
    )
    let second = RecordedRequest(
        httpRequest: request,
        preparedBody: .file(secondFile),
        requestID: RequestID(rawValue: UUID()),
        attemptNumber: 1,
        requestContext: RequestContext(),
    )

    let sanitizedFirst = await rendered(.recordedRequest, first)
    let sanitizedSecond = await rendered(.recordedRequest, second)
    #expect(sanitizedFirst == sanitizedSecond)
    #expect(sanitizedFirst.contains("<request-id>"))
    #expect(sanitizedFirst.contains("<generated-location>"))
    #expect(sanitizedFirst.contains("byteCount"))
    #expect(!sanitizedFirst.contains(first.requestID.rawValue.uuidString))
    #expect(!sanitizedFirst.contains("file-backed-secret"))
    #expect(try Data(contentsOf: firstFile) == Data("file-backed-secret".utf8))

    let exact = await rendered(.recordedRequest(.exact), first)
    #expect(exact.contains(first.requestID.rawValue.uuidString))
    #expect(exact.contains(firstFile.path))

    for output in [sanitizedFirst, exact] {
        #expect(output.contains("<redacted>"))
        #expect(output.contains("token="))
        #expect(output.contains("application/json"))
        #expect(!output.contains("secret-token"))
        #expect(!output.contains("secret-cookie"))
        #expect(!output.contains("secret-query"))
    }

    assertSnapshot(of: first, as: .recordedRequest)
}

@Test("Network event snapshots sanitize identities, timestamps, and error descriptions")
func networkEventSnapshotsSanitizeRunSpecificValues() async {
    let events = makeEvents(requestID: RequestID(rawValue: UUID()), timestamp: Date(timeIntervalSince1970: 1_000_000))
    let otherEvents = makeEvents(
        requestID: RequestID(rawValue: UUID()),
        timestamp: Date(timeIntervalSince1970: 2_000_000),
    )

    let sanitized = await rendered(.networkEvents, events)
    let otherSanitized = await rendered(.networkEvents, otherEvents)
    #expect(sanitized == otherSanitized)
    #expect(sanitized.contains("<timestamp>"))
    #expect(sanitized.contains("SecretBearingError"))
    #expect(!sanitized.contains("private.example"))
    #expect(!sanitized.contains("secret-value"))

    let exact = await rendered(.networkEvents(.exact), events)
    #expect(exact.contains("1970-01-12T13:46:40.000000000Z"))
    #expect(!exact.contains("private.example"))

    assertSnapshot(of: events, as: .networkEvents)
}

@Test("Attempt history snapshots sanitize identities, durations, and diagnostic text")
func attemptHistorySnapshotsSanitizeUnstableValues() async {
    let requestID = RequestID(rawValue: UUID())
    let attempts = makeAttemptHistory(requestID: requestID)

    let sanitized = await rendered(.attemptHistory, attempts)
    #expect(sanitized.contains("<request-id>"))
    #expect(sanitized.contains("<duration>"))
    #expect(sanitized.contains("<present>"))
    #expect(!sanitized.contains("private.example"))
    #expect(sanitized.contains("acceptedResponse"))

    let exact = await rendered(.attemptHistory(.exact), attempts)
    #expect(exact.contains(requestID.rawValue.uuidString))
    #expect(exact.contains("2s"))
    #expect(!exact.contains("private.example"))

    assertSnapshot(of: attempts, as: .attemptHistory)
}

@Test("Exact duration rendering keeps sub-nanosecond precision")
func exactDurationRenderingKeepsSubNanosecondPrecision() async {
    let attempts = [
        AttemptMetrics(
            requestID: RequestID(rawValue: UUID()),
            attemptNumber: 1,
            normalizedMetrics: NormalizedAttemptMetrics(
                duration: Duration(secondsComponent: 0, attosecondsComponent: 1),
                redirectCount: 0,
            ),
            outcome: .acceptedResponse,
            diagnosticReason: nil,
            rawTaskMetrics: nil,
        ),
    ]

    let exact = await rendered(.attemptHistory(.exact), attempts)
    #expect(exact.contains("0.000000000000000001s"))
}

@Test("Response snapshots render decoded values, status, and retained body metadata")
func responseSnapshotsRenderDecodedValues() async {
    let requestID = RequestID(rawValue: UUID())
    let retained = Data(#"{"name":"daniel","count":2}"#.utf8)
    let response = Response(
        value: SamplePayload(name: "daniel", count: 2),
        httpResponse: HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        requestID: requestID,
        attempts: makeAttemptHistory(requestID: requestID),
        retainedBody: RetainedBody(data: retained, originalByteCount: Int64(retained.count) + 100),
    )

    let sanitized = await rendered(.response(), response)
    #expect(sanitized.contains("<request-id>"))
    #expect(sanitized.contains("isTruncated: true"))
    #expect(!sanitized.contains(requestID.rawValue.uuidString))
    #expect(!sanitized.contains(#""name": "daniel""#))

    let exact = await rendered(.response(.exact), response)
    #expect(exact.contains(requestID.rawValue.uuidString))
    #expect(!exact.contains(#""name": "daniel""#))

    assertSnapshot(of: response, as: .response())
}

@Test("Snapshotting a downloaded response never transfers file cleanup ownership")
func responseSnapshotsDoNotTransferDownloadOwnership() async throws {
    let url = try #require(URL(string: "https://mock.example/download"))
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .download(data: Data([0, 1, 2, 255]), response: HTTPResponse(status: .ok)),
    )
    let client = try NetworkClient.testing(transport: MockNetworkTransport(stubs: [stub]))
    let endpoint = Endpoint<Never, Never, DownloadedFile>.download(method: .get, route: .absolute(url))

    let response = try await client.send(Request(endpoint: endpoint))
    let storage = response.value.ownership
    let temporaryPath = storage.url.path
    defer { try? FileManager.default.removeItem(atPath: temporaryPath) }
    #expect(FileManager.default.fileExists(atPath: temporaryPath))

    let sanitized = await rendered(.response(), response)
    #expect(sanitized.contains("<generated-location>"))
    #expect(!sanitized.contains(temporaryPath))

    let exact = await rendered(.response(.exact), response)
    #expect(exact.contains(temporaryPath))

    // Cleanup still removes the file only while the library owns it; reading the public URL once
    // would transfer ownership and make this discard a no-op.
    storage.discard()
    #expect(!FileManager.default.fileExists(atPath: temporaryPath))
}

@Test("JSON snapshot strategy renders canonical deterministic JSON")
func jsonSnapshotsRenderCanonicalJSON() throws {
    let fixture = try JSONFixture(json: #"{"b":1,"a":[3,1],"n":1e400}"#)

    assertSnapshot(of: fixture, as: .json)
}

@Test("Additional sensitive headers stay redacted in both stability modes")
func additionalSensitiveHeadersStayRedacted() async throws {
    let apiKeyName = try #require(HTTPField.Name("X-API-Key"))
    let traceName = try #require(HTTPField.Name("X-Trace"))
    let requestID = RequestID(rawValue: UUID())
    let request = HTTPRequest(
        method: .post,
        scheme: "https",
        authority: "example.com",
        path: "/upload",
        headerFields: [
            .authorization: "Bearer secret-token",
            apiKeyName: "secret-api-key",
            traceName: "trace-123",
        ],
    )
    let recorded = RecordedRequest(
        httpRequest: request,
        preparedBody: .none,
        requestID: requestID,
        attemptNumber: 1,
        requestContext: RequestContext(),
    )

    for output in await [
        rendered(.recordedRequest(.sanitized, additionalSensitiveHeaders: ["X-API-Key"]), recorded),
        rendered(.recordedRequest(.exact, additionalSensitiveHeaders: ["X-API-Key"]), recorded),
    ] {
        #expect(!output.contains("secret-api-key"))
        #expect(!output.contains("secret-token"))
        #expect(output.contains("trace-123"))
        #expect(output.contains("<redacted>"))
    }

    let response = Response(
        value: SamplePayload(name: "daniel", count: 2),
        httpResponse: HTTPResponse(
            status: .ok,
            headerFields: [apiKeyName: "response-api-key", traceName: "trace-123"],
        ),
        requestID: requestID,
    )

    for output in await [
        rendered(.response(additionalSensitiveHeaders: ["X-API-Key"]), response),
        rendered(.response(.exact, additionalSensitiveHeaders: ["X-API-Key"]), response),
    ] {
        #expect(!output.contains("response-api-key"))
        #expect(output.contains("trace-123"))
    }

    let events = makeHeaderBearingEvents(requestID: requestID, headerFields: [apiKeyName: "event-api-key"])

    for output in await [
        rendered(.networkEvents(.sanitized, additionalSensitiveHeaders: ["X-API-Key"]), events),
        rendered(.networkEvents(.exact, additionalSensitiveHeaders: ["X-API-Key"]), events),
    ] {
        #expect(!output.contains("event-api-key"))
    }
}

@Test("Sanitized collections keep request identity relationships")
func sanitizedCollectionsKeepRequestIdentityRelationships() async {
    let firstID = RequestID(rawValue: UUID())
    let secondID = RequestID(rawValue: UUID())
    let events = makeTwoIdentityEvents(firstID: firstID, secondID: secondID)

    let sanitized = await rendered(.networkEvents, events)
    #expect(sanitized.contains("<request-id-1>"))
    #expect(sanitized.contains("<request-id-2>"))
    #expect(!sanitized.contains(firstID.rawValue.uuidString))
    #expect(!sanitized.contains(secondID.rawValue.uuidString))
    #expect(occurrences(of: "<request-id-1>", in: sanitized) == 2)
    #expect(occurrences(of: "<request-id-2>", in: sanitized) == 1)

    let otherEvents = makeTwoIdentityEvents(
        firstID: RequestID(rawValue: UUID()),
        secondID: RequestID(rawValue: UUID()),
    )
    #expect(await rendered(.networkEvents, otherEvents) == sanitized)

    let exact = await rendered(.networkEvents(.exact), events)
    #expect(exact.contains(firstID.rawValue.uuidString))
    #expect(exact.contains(secondID.rawValue.uuidString))

    let history = await rendered(.attemptHistory, makeTwoIdentityAttempts(firstID: firstID, secondID: secondID))
    #expect(history.contains("<request-id-1>"))
    #expect(history.contains("<request-id-2>"))
}

@Test("Exact timestamps preserve Date values that collapse through the Unix epoch")
func exactTimestampsPreserveDistinctDateValues() async throws {
    let requestID = RequestID(rawValue: UUID())
    let values = [
        Date(timeIntervalSinceReferenceDate: 0),
        Date(timeIntervalSinceReferenceDate: 1e-9),
        Date(timeIntervalSinceReferenceDate: 21_692_800.25),
        Date(timeIntervalSinceReferenceDate: 21_692_800.5),
    ]

    var outputs: [String] = []
    for value in values {
        let output = await rendered(
            .networkEvents(.exact),
            makeEvents(requestID: requestID, timestamp: value),
        )
        let renderedInterval = try #require(referenceInterval(in: output))
        #expect(renderedInterval.bitPattern == value.timeIntervalSinceReferenceDate.bitPattern)
        outputs.append(output)
    }

    // The two reference-date values share one Unix epoch second, so an epoch-based representation
    // renders them identically; exact output must still tell them apart.
    #expect(Set(outputs).count == values.count)
    #expect(outputs[0].contains("2001-01-01T00:00:00.000000000Z (reference interval: 0)"))
    #expect(outputs[1].contains("2001-01-01T00:00:00.000000001Z (reference interval: 1e-09)"))

    let repeated = await rendered(
        .networkEvents(.exact),
        makeEvents(requestID: requestID, timestamp: values[1]),
    )
    #expect(repeated == outputs[1])

    let sanitized = await rendered(
        .networkEvents,
        makeEvents(requestID: requestID, timestamp: values[1]),
    )
    #expect(sanitized.contains("<timestamp>"))
    #expect(!sanitized.contains("2001-01-01"))
}

private func rendered<Value>(_ strategy: Snapshotting<Value, String>, _ value: Value) async -> String {
    await withCheckedContinuation { continuation in
        strategy.snapshot(value).run { text in
            continuation.resume(returning: text)
        }
    }
}

private func makeTemporaryBodyFile(contents: String) throws -> URL {
    let url = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("swift-networking-snapshot-body-" + UUID().uuidString)
    try Data(contents.utf8).write(to: url)
    return url
}

private func makeHeaderBearingEvents(requestID: RequestID, headerFields: HTTPFields) -> [NetworkEvent] {
    [
        .responseReceived(
            ResponseReceivedEvent(
                requestID: requestID,
                timestamp: Date(timeIntervalSince1970: 1_000_000),
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource"),
                httpResponse: HTTPResponse(status: .ok, headerFields: headerFields),
                normalizedMetrics: NormalizedAttemptMetrics(duration: .seconds(1), redirectCount: 0),
                rawTaskMetrics: nil,
            ),
        ),
    ]
}

private func makeTwoIdentityEvents(firstID: RequestID, secondID: RequestID) -> [NetworkEvent] {
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource")

    return [
        .requestStarted(
            RequestStartedEvent(requestID: firstID, timestamp: timestamp, requestContext: RequestContext()),
        ),
        .attemptStarted(
            AttemptStartedEvent(
                requestID: firstID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: request,
            ),
        ),
        .requestStarted(
            RequestStartedEvent(requestID: secondID, timestamp: timestamp, requestContext: RequestContext()),
        ),
    ]
}

private func makeTwoIdentityAttempts(firstID: RequestID, secondID: RequestID) -> [AttemptMetrics] {
    [firstID, secondID].map { requestID in
        AttemptMetrics(
            requestID: requestID,
            attemptNumber: 1,
            normalizedMetrics: NormalizedAttemptMetrics(duration: .seconds(1), redirectCount: 0),
            outcome: .acceptedResponse,
            diagnosticReason: nil,
            rawTaskMetrics: nil,
        )
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Extracts the exact reference-date interval that the projection renderer appends to timestamps.
private func referenceInterval(in snapshot: String) -> Double? {
    guard let marker = snapshot.range(of: "(reference interval: ") else {
        return nil
    }
    guard let end = snapshot[marker.upperBound...].firstIndex(of: ")") else {
        return nil
    }

    return Double(snapshot[marker.upperBound ..< end])
}

private func makeAttemptHistory(requestID: RequestID) -> [AttemptMetrics] {
    [
        AttemptMetrics(
            requestID: requestID,
            attemptNumber: 1,
            normalizedMetrics: NormalizedAttemptMetrics(duration: .seconds(2), redirectCount: 0),
            outcome: .acceptedResponse,
            diagnosticReason: nil,
            rawTaskMetrics: nil,
        ),
        AttemptMetrics(
            requestID: requestID,
            attemptNumber: 2,
            normalizedMetrics: NormalizedAttemptMetrics(duration: .seconds(3), redirectCount: 1),
            outcome: .validationRejection,
            diagnosticReason: "validation rejected the response at https://private.example/token",
            rawTaskMetrics: nil,
        ),
    ]
}

private func makeEvents(requestID: RequestID, timestamp: Date) -> [NetworkEvent] {
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource")
    let response = HTTPResponse(status: .ok)
    let metrics = NormalizedAttemptMetrics(duration: .seconds(1), redirectCount: 0)

    return [
        .requestStarted(
            RequestStartedEvent(requestID: requestID, timestamp: timestamp, requestContext: RequestContext()),
        ),
        .attemptStarted(
            AttemptStartedEvent(
                requestID: requestID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: request,
            ),
        ),
        .responseReceived(
            ResponseReceivedEvent(
                requestID: requestID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: request,
                httpResponse: response,
                normalizedMetrics: metrics,
                rawTaskMetrics: nil,
            ),
        ),
        .attemptFailed(
            AttemptFailedEvent(
                requestID: requestID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: request,
                error: SecretBearingError(),
                normalizedMetrics: metrics,
                rawTaskMetrics: nil,
            ),
        ),
        .retryScheduled(
            RetryScheduledEvent(
                requestID: requestID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                attemptNumber: 1,
                request: request,
                httpResponse: response,
                transportError: nil,
                delay: .seconds(2),
                normalizedMetrics: metrics,
                rawTaskMetrics: nil,
            ),
        ),
        .requestCompleted(
            RequestCompletedEvent(
                requestID: requestID,
                timestamp: timestamp,
                requestContext: RequestContext(),
                httpResponse: response,
                attempts: makeAttemptHistory(requestID: requestID),
            ),
        ),
    ]
}
