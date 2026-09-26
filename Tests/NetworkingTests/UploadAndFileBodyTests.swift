//
//  UploadAndFileBodyTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct UploadAndFileBodyTests {
    @Test("Bodyful upload endpoints use upload-from-data and decode typed responses")
    func uploadEndpointUsesUploadFromDataAndDecodesResponse() async throws {
        let payload = Data([0x01, 0x02, 0x03])
        let responseBody = Data(#"{"identifier":"asset-7"}"#.utf8)
        let uploadURL = try makeURL()
        let endpoint = Endpoint<Never, Data, UploadReceipt>.upload(
            method: .post,
            route: .absolute(uploadURL),
            body: .data(contentType: "application/octet-stream"),
            response: .json(),
        )
        let transport = RecordingUploadTransport(responseBody: responseBody)
        let client = try NetworkClient(transport: transport)

        let response = try await client.send(Request(endpoint: endpoint, body: payload))

        #expect(response.value == UploadReceipt(identifier: "asset-7"))
        let sentRequest = try #require(await transport.recordedRequests().first)
        #expect(sentRequest.operation == .upload)
        #expect(sentRequest.execution == .uploadFromData(payload))
        #expect(response.attempts.map(\.outcome) == [.acceptedResponse])
    }

    @Test("Bodyful upload endpoints use upload-from-file without replacing the source URL")
    func uploadEndpointUsesUploadFromFile() async throws {
        let sourceURL = try makeTemporaryFile(contents: Data([0x04, 0x05]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let uploadURL = try makeURL()
        let endpoint = Endpoint<Never, URL, Data>.upload(
            method: .post,
            route: .absolute(uploadURL),
            body: .file(contentType: "application/x-upload"),
            response: .data,
        )
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(transport: transport)

        _ = try await client.send(Request(endpoint: endpoint, body: sourceURL))

        let sentRequest = try #require(await transport.recordedRequests().first)
        #expect(sentRequest.operation == .upload)
        guard case let .file(recordedURL) = sentRequest.body else {
            Issue.record("Expected the original source URL to remain file-backed")
            return
        }

        #expect(recordedURL == sourceURL)
        #expect(sentRequest.execution == .uploadFromFile(sourceURL))
    }

    @Test("File content type uses the existing client, endpoint, and request precedence")
    func fileContentTypeUsesHeaderPrecedence() async throws {
        let sourceURL = try makeTemporaryFile(contents: Data([0x06]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let endpoint = try makeFileDataEndpoint()
            .header(.contentType, "application/x-endpoint")
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withDefaultHeaders(
                HTTPFields([HTTPField(name: .contentType, value: "application/x-client")]),
            ),
        )
        let request = Request(endpoint: endpoint, body: sourceURL)
            .header(.contentType, "application/x-request")

        _ = try await client.send(request)

        let sentRequest = try #require(await transport.recordedRequests().first)
        #expect(headerValues(.contentType, in: sentRequest.httpRequest.headerFields) == ["application/x-request"])
    }

    @Test("Operation and body representations select the matching URLSession task family")
    func operationAndBodySelectTaskFamily() {
        let payload = Data([1, 2])
        let fileURL = URL(fileURLWithPath: "/tmp/body.bin")

        #expect(TransportExecution.resolve(operation: .data, body: .none) == .data(body: nil))
        #expect(
            TransportExecution.resolve(operation: .data, body: .data(payload)) == .data(body: payload),
        )
        #expect(
            TransportExecution.resolve(operation: .data, body: .file(fileURL)) == .uploadFromFile(fileURL),
        )
        #expect(
            TransportExecution.resolve(operation: .upload, body: .data(payload)) == .uploadFromData(payload),
        )
        #expect(
            TransportExecution.resolve(operation: .upload, body: .file(fileURL)) == .uploadFromFile(fileURL),
        )
        #expect(TransportExecution.resolve(operation: .upload, body: .none) == nil)
        #expect(TransportExecution.resolve(operation: .download, body: .file(fileURL)) == nil)
    }

    @Test("Endpoint and request copies preserve upload operation semantics")
    func copiesPreserveUploadOperation() throws {
        let uploadURL = try makeURL()
        let endpoint = Endpoint<Never, Data, Data>.upload(
            method: .post,
            route: .absolute(uploadURL),
            body: .data(),
            response: .data,
        )
        let endpointCopies = [
            endpoint.headers(HTTPFields()),
            endpoint.header(.accept, "application/octet-stream"),
            endpoint.jsonEncoderConfiguration { $0.outputFormatting = .sortedKeys },
            endpoint.jsonDecoderConfiguration { _ in },
            endpoint.validationPolicy(.successfulStatusCodes),
            endpoint.successfulResponseBodyRetentionPolicy(.none),
            endpoint.validationErrorBodyRetentionPolicy(.unlimited),
            endpoint.authenticationRequirement(.required()),
            endpoint.retryPolicy(RetryPolicy()),
            endpoint.redirectPolicy(.follow),
        ]

        #expect(endpointCopies.allSatisfy { $0.operation == .upload })

        let request = Request(endpoint: endpoint, body: Data([8]))
        let requestCopies = [
            request.queryItems([URLQueryItem(name: "trace", value: "copy")]),
            request.headers(HTTPFields()),
            request.header(.accept, "application/octet-stream"),
            request.validationPolicy(.successfulStatusCodes),
            request.successfulResponseBodyRetentionPolicy(.none),
            request.validationErrorBodyRetentionPolicy(.unlimited),
            request.retryPolicy(RetryPolicy()),
            request.redirectPolicy(.follow),
        ]

        #expect(requestCopies.allSatisfy { $0.operation == .upload })
    }

    @Test("A directory is rejected as an unreadable file body before transport")
    func directoryFileBodyFailsBeforeTransport() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-directory-\(UUID().uuidString)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let endpoint = try makeFileDataEndpoint()
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: Request(endpoint: endpoint, body: directoryURL))

        do {
            _ = try await task.value
            Issue.record("Expected a directory body to fail before transport")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unreadableFileBody)
            #expect(error.requestID == task.requestID)
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("A non-file URL is rejected as an unreadable file body before transport")
    func nonFileURLBodyFailsBeforeTransport() async throws {
        let remoteURL = try #require(URL(string: "https://example.com/body.bin"))
        let endpoint = try makeFileDataEndpoint()
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: Request(endpoint: endpoint, body: remoteURL))

        do {
            _ = try await task.value
            Issue.record("Expected a non-file URL body to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unreadableFileBody)
            #expect(error.requestID == task.requestID)
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Download and file-body incompatibility is rejected before file validation")
    func downloadFileCombinationFailsBeforeFileValidation() async throws {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-download-body-\(UUID().uuidString).bin",
        )
        let endpoint = try makeFileDataEndpoint().withOperation(.download)
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: Request(endpoint: endpoint, body: missingURL))

        do {
            _ = try await task.value
            Issue.record("Expected an unsupported download/file-body combination to fail")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unsupportedOperationBodyCombination)
            #expect(error.requestID == task.requestID)
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("A file removed before ordinary retry fails without starting another transport attempt")
    func fileRemovedBeforeRetryDoesNotStartAnotherAttempt() async throws {
        let sourceURL = try makeTemporaryFile(contents: Data([9]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let adapterCalls = CallCounter()
        let adapter = AnyRequestAdapter(adapt: { context in
            await adapterCalls.increment()
            return context.request
        })
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.retryableMethods = [.post]
        retryConfiguration.retryableStatusCodes = [418]
        let transport = RemovingFileTransport(fileURL: sourceURL, firstStatusCode: 418)
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withRetryPolicy(RetryPolicy(configuration: retryConfiguration))
                .withRequestAdapter(adapter),
        )
        let endpoint = try makeFileDataEndpoint()
        let task = client.task(for: Request(endpoint: endpoint, body: sourceURL))

        do {
            _ = try await task.value
            Issue.record("Expected the removed retry body to fail pretransport")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unreadableFileBody)
            #expect(error.requestID == task.requestID)
        }

        let sentRequests = await transport.recordedRequests()
        #expect(sentRequests.count == 1)
        #expect(sentRequests.first?.attemptNumber == 1)
        #expect(sentRequests.first?.execution == .uploadFromFile(sourceURL))
        #expect(await adapterCalls.count() == 1)
    }

    @Test("A file removed before authentication replay fails before the next adaptation")
    func fileRemovedBeforeAuthenticationReplayDoesNotStartAnotherAttempt() async throws {
        let sourceURL = try makeTemporaryFile(contents: Data([7]))
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let adapterCalls = CallCounter()
        let adapter = AnyRequestAdapter(adapt: { context in
            await adapterCalls.increment()
            return context.request
        })
        let provider = RecordingAuthenticationProvider(fileURLToRemove: sourceURL)
        let transport = UnauthorizedUploadTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withAuthenticationProvider(provider)
                .withRequestAdapter(adapter),
        )
        let endpoint = try makeFileDataEndpoint()
            .authenticationRequirement(.required(maximumReplays: 1))
        let task = client.task(for: Request(endpoint: endpoint, body: sourceURL))

        do {
            _ = try await task.value
            Issue.record("Expected the removed replay body to fail pretransport")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unreadableFileBody)
            #expect(error.requestID == task.requestID)
        }

        #expect(await transport.recordedRequests().count == 1)
        #expect(await provider.adaptationCount() == 1)
        #expect(await provider.recoveryCount() == 1)
        #expect(await adapterCalls.count() == 1)
    }

    @Test("An initially missing file fails before general and authentication adaptation")
    func missingFileFailsBeforeAnyAdaptation() async throws {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-initial-missing-\(UUID().uuidString).bin",
        )
        let adapterCalls = CallCounter()
        let adapter = AnyRequestAdapter(adapt: { context in
            await adapterCalls.increment()
            return context.request
        })
        let provider = RecordingAuthenticationProvider()
        let transport = RecordingUploadTransport()
        let client = try NetworkClient(
            transport: transport,
            configuration: .init()
                .withAuthenticationProvider(provider)
                .withRequestAdapter(adapter),
        )
        let endpoint = try makeFileDataEndpoint()
            .authenticationRequirement(.required())
        let task = client.task(for: Request(endpoint: endpoint, body: missingURL))

        do {
            _ = try await task.value
            Issue.record("Expected the missing file body to fail before adaptation")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unreadableFileBody)
            #expect(error.requestID == task.requestID)
        }

        #expect(await adapterCalls.count() == 0)
        #expect(await provider.adaptationCount() == 0)
        #expect(await provider.recoveryCount() == 0)
        #expect(await transport.recordedRequests().isEmpty)
    }
}

private struct UploadReceipt: Decodable, Sendable, Equatable {
    let identifier: String
}

private func makeURL() throws -> URL {
    try #require(URL(string: "https://example.com/upload"))
}

private func makeFileDataEndpoint() throws -> Endpoint<Never, URL, Data> {
    let uploadURL = try makeURL()
    return Endpoint<Never, URL, Data>.data(
        method: .post,
        route: .absolute(uploadURL),
        body: .file(contentType: "application/octet-stream"),
        response: .data,
    )
}

private func makeTemporaryFile(contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-networking-upload-\(UUID().uuidString).bin",
    )
    try contents.write(to: url)
    return url
}

private func headerValues(_ name: HTTPField.Name, in fields: HTTPFields) -> [String] {
    fields.filter { $0.name == name }.map(\.value)
}

private actor RecordingUploadTransport: NetworkTransport {
    private var requests: [TransportRequest] = []
    private let responseBody: Data

    init(responseBody body: Data = Data([0x2a])) {
        responseBody = body
    }

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        return (responseBody, HTTPResponse(status: .init(code: 200)))
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }
}

private actor RemovingFileTransport: NetworkTransport {
    private let fileURL: URL
    private let firstStatusCode: Int
    private var requests: [TransportRequest] = []

    init(fileURL sourceURL: URL, firstStatusCode statusCode: Int) {
        fileURL = sourceURL
        firstStatusCode = statusCode
    }

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        if requests.count == 1 {
            try FileManager.default.removeItem(at: fileURL)
            return (Data(), HTTPResponse(status: .init(code: firstStatusCode)))
        }
        return (Data([0x2a]), HTTPResponse(status: .init(code: 200)))
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }
}

private actor UnauthorizedUploadTransport: NetworkTransport {
    private var requests: [TransportRequest] = []

    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        requests.append(request)
        return (Data(), HTTPResponse(status: .init(code: 401)))
    }

    func recordedRequests() -> [TransportRequest] {
        requests
    }
}

private actor CallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private actor RecordingAuthenticationProvider: AuthenticationProvider {
    private let fileURLToRemove: URL?
    private var adaptations = 0
    private var recoveries = 0

    init(fileURLToRemove sourceURL: URL? = nil) {
        fileURLToRemove = sourceURL
    }

    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        adaptations += 1
        return context.request
    }

    func recover(_: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        recoveries += 1
        if let fileURLToRemove {
            try FileManager.default.removeItem(at: fileURLToRemove)
        }
        return fileURLToRemove == nil ? .doNotReplay : .replay
    }

    func adaptationCount() -> Int {
        adaptations
    }

    func recoveryCount() -> Int {
        recoveries
    }
}
