//
//  DownloadExecutionTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct DownloadExecutionTests {
    @Test("Accepted downloads validate through a file URL and transfer temporary ownership")
    func acceptedDownloadRetainsTheFileWithoutRawBodyRetention() async throws {
        let responseBody = Data([0x31, 0x32, 0x33, 0x34])
        let transport = ScriptedDownloadTransport([.init(body: responseBody, statusCode: 200)])
        let observations = ValidationFileRecorder()
        let validationPolicy = ResponseValidationPolicy.custom { context in
            if case let .file(url) = context.receivedBody {
                let bodyDuringCallback = try? Data(contentsOf: url)
                observations.record(
                    DownloadFileObservation(
                        url: url,
                        existsDuringCallback: FileManager.default.fileExists(atPath: url.path),
                        bodyDuringCallback: bodyDuringCallback,
                    ),
                )
            }
            return .accept
        }
        let configuration = NetworkClient.Configuration()
            .withResponseValidationPolicy(validationPolicy)
            .withSuccessfulResponseBodyRetentionPolicy(.unlimited)
        let client = try NetworkClient(transport: transport, configuration: configuration)

        let response = try await client.send(Request(endpoint: makeDownloadEndpoint()))
        let createdURLs = await transport.createdFileURLs()
        let fileURL = try #require(createdURLs.first)

        let firstReference = response.value
        let secondReference = response.value
        #expect(firstReference === secondReference)
        #expect(response.value.ownership.url == fileURL)
        #expect(response.retainedBody == nil)
        #expect(response.attempts.map(\.outcome) == [.acceptedResponse])
        let validationObservations = observations.values()
        #expect(validationObservations == [
            DownloadFileObservation(
                url: fileURL,
                existsDuringCallback: true,
                bodyDuringCallback: responseBody,
            ),
        ])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        response.value.ownership.discard()
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("Authentication recovery receives a file URL and replay removes it before the next attempt")
    func authenticationReplayDiscardsTheCompletedAttemptFile() async throws {
        let transport = ScriptedDownloadTransport([
            .init(body: Data([0x41]), statusCode: 401),
            .init(body: Data([0x42, 0x43]), statusCode: 200),
        ])
        let recovery = DownloadAuthenticationScript([.replay])
        let endpoint = try makeDownloadEndpoint().authenticationRequirement(.required(maximumReplays: 1))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(
                ScriptedDownloadAuthenticationProvider(script: recovery),
            ),
        )

        let response = try await client.send(Request(endpoint: endpoint))
        let fileURLs = await transport.createdFileURLs()
        let callbackContexts = await recovery.recordedContexts()
        let callbackURL = try #require(callbackContexts.first.flatMap {
            fileURL(in: $0.receivedBody)
        })

        #expect(fileURLs.count == 2)
        #expect(callbackURL == fileURLs.first)
        #expect(await transport.previousFilePresenceAtAttemptStarts() == [false])
        #expect(FileManager.default.fileExists(atPath: callbackURL.path) == false)
        #expect(response.attempts.map(\.outcome) == [.authenticationReplayScheduled, .acceptedResponse])
        #expect(response.attempts.map(\.attemptNumber) == [1, 2])
        #expect(FileManager.default.fileExists(atPath: response.value.ownership.url.path))

        response.value.ownership.discard()
    }

    @Test("Authentication errors remove a materialized download file")
    func authenticationFailureDiscardsTheCompletedAttemptFile() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0x51]), statusCode: 401)])
        let recovery = DownloadAuthenticationScript([.failure])
        let endpoint = try makeDownloadEndpoint().authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(
                ScriptedDownloadAuthenticationProvider(script: recovery),
            ),
        )
        let task = client.task(for: Request(endpoint: endpoint))

        do {
            _ = try await task.value
            Issue.record("Expected authentication recovery to fail")
        } catch let error as DownloadExecutionTestError {
            #expect(error == .recoveryFailed)
        } catch {
            Issue.record("Unexpected error from authentication recovery: \(error)")
        }

        let fileURL = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("Cancellation during authentication recovery removes the current download file")
    func cancellationDuringAuthenticationRecoveryDiscardsTheCompletedAttemptFile() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0x61]), statusCode: 401)])
        let recovery = DownloadAuthenticationScript([.suspend])
        let endpoint = try makeDownloadEndpoint().authenticationRequirement(.required())
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(
                ScriptedDownloadAuthenticationProvider(script: recovery),
            ),
        )
        let task = client.task(for: Request(endpoint: endpoint))

        await recovery.waitUntilRecoveryStarts()
        let fileURL = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected explicit task cancellation to surface CancellationError")
        } catch is CancellationError {
            // The shared task preserves cancellation for its value awaiters.
        } catch {
            Issue.record("Unexpected error after task cancellation: \(error)")
        }

        await waitForRemoval(of: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("Retry removes the completed download before the delay and resets attempt progress")
    func retryDiscardsFileBeforeDelayAndStartsFreshProgress() async throws {
        let firstBody = Data([0x71, 0x72, 0x73])
        let finalBody = Data([0x81, 0x82])
        let transport = ScriptedDownloadTransport([
            .init(body: firstBody, statusCode: 503),
            .init(body: finalBody, statusCode: 200),
        ])
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.backoffStrategy = .constant(.seconds(2), jitter: .none)
        retryConfiguration.retryableStatusCodes = [503]
        let sleepObservations = Mutex<[RetrySleepObservation]>([])
        let timing = RetryTimingDependencies(
            sleep: { delay in
                let previousURL = await transport.createdFileURLs().last
                let previousWasRemoved = previousURL.map {
                    FileManager.default.fileExists(atPath: $0.path) == false
                } ?? false
                sleepObservations.withLock {
                    $0.append(RetrySleepObservation(delay: delay, previousWasRemoved: previousWasRemoved))
                }
            },
            now: { Date(timeIntervalSince1970: 0) },
            randomUnit: { 0.5 },
        )
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
            retryTimingDependencies: timing,
        )
        let endpoint = try makeDownloadEndpoint()
        let task = client.task(for: Request(endpoint: endpoint))

        let response = try await task.value
        let fileURLs = await transport.createdFileURLs()
        var progressIterator = task.progress.makeAsyncIterator()
        let finalProgress = try #require(await progressIterator.next())

        #expect(fileURLs.count == 2)
        #expect(await transport.previousFilePresenceAtAttemptStarts() == [false])
        #expect(sleepObservations.withLock { $0 } == [
            RetrySleepObservation(delay: .seconds(2), previousWasRemoved: true),
        ])
        #expect(await transport.attemptNumbers() == [1, 2])
        #expect(response.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
        #expect(response.attempts.map(\.attemptNumber) == [1, 2])
        #expect(finalProgress.attemptNumber == 2)
        #expect(finalProgress.bytesReceived == Int64(finalBody.count))
        #expect(finalProgress.isComplete)

        response.value.ownership.discard()
    }

    @Test("Rejected downloads retain the configured prefix and remove the file")
    func validationRejectionRetainsPrefixAndPreservesAttemptHistory() async throws {
        let discardedBody = Data([0x91, 0x92])
        let rejectedBody = Data([0xa1, 0xa2, 0xa3, 0xa4, 0xa5])
        let transport = ScriptedDownloadTransport([
            .init(body: discardedBody, statusCode: 503),
            .init(body: rejectedBody, statusCode: 403),
        ])
        let observations = ValidationFileRecorder()
        let validationPolicy = ResponseValidationPolicy.custom { context in
            if case let .file(url) = context.receivedBody {
                let bodyDuringCallback = try? Data(contentsOf: url)
                observations.record(
                    DownloadFileObservation(
                        url: url,
                        existsDuringCallback: FileManager.default.fileExists(atPath: url.path),
                        bodyDuringCallback: bodyDuringCallback,
                    ),
                )
            }
            return .reject(reason: "download denied")
        }
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.retryableStatusCodes = [503]
        let endpoint = try makeDownloadEndpoint()
        let request = Request(endpoint: endpoint)
            .retryPolicy(RetryPolicy(configuration: retryConfiguration))
            .validationPolicy(validationPolicy)
            .validationErrorBodyRetentionPolicy(.upTo(2))
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected response validation to reject the download")
        } catch let error as ResponseValidationError {
            let fileURLs = await transport.createdFileURLs()
            let rejectedURL = try #require(fileURLs.last)
            #expect(error.httpResponse.status.code == 403)
            #expect(error.reason == "download denied")
            #expect(error.requestID == task.requestID)
            #expect(error.attempts.map(\.attemptNumber) == [1, 2])
            #expect(error.attempts.map(\.outcome) == [.retryScheduled, .validationRejection])
            #expect(error.retainedBody?.data == Data([0xa1, 0xa2]))
            #expect(error.retainedBody?.originalByteCount == Int64(rejectedBody.count))
            #expect(error.retainedBody?.isTruncated == true)
            let validationObservations = observations.values()
            #expect(validationObservations.last?.url == rejectedURL)
            #expect(validationObservations.last?.existsDuringCallback == true)
            #expect(FileManager.default.fileExists(atPath: rejectedURL.path) == false)
            #expect(await transport.previousFilePresenceAtAttemptStarts() == [false])
        } catch {
            Issue.record("Unexpected error from response validation: \(error)")
        }
    }

    @Test("File-backed request bodies fail download preflight before progress, adapters, or transport")
    func fileBackedRequestBodyFailsBeforeAttempt() async throws {
        let url = try #require(URL(string: "https://download.test/file-body"))
        let route = try #require(URL(string: "https://download.test/upload"))
        let endpoint = Endpoint<Never, URL, DownloadedFile>.download(
            method: .post,
            route: .absolute(route),
            body: .file(contentType: "application/octet-stream"),
        )
        let transport = ScriptedDownloadTransport([])
        let adapterCalls = Mutex(0)
        let configuration = NetworkClient.Configuration().withRequestAdapter(
            AnyRequestAdapter(adapt: { context in
                adapterCalls.withLock { $0 += 1 }
                return context.request
            }),
        )
        let client = try NetworkClient(transport: transport, configuration: configuration)
        let task = client.task(for: Request(endpoint: endpoint, body: url))
        var progressIterator = task.progress.makeAsyncIterator()
        let initialProgress = await progressIterator.next()

        do {
            _ = try await task.value
            Issue.record("Expected a file-backed download request body to fail preflight")
        } catch let error as RequestConstructionError {
            #expect(error.reason == .unsupportedOperationBodyCombination)
            #expect(error.requestID == task.requestID)
        }

        #expect(initialProgress?.attemptNumber == nil)
        #expect(adapterCalls.withLock { $0 } == 0)
        #expect(await transport.executionCount() == 0)
    }

    @Test("An abandoned ownership token automatically removes its library temporary file")
    func ownershipTokenCleansUpWhenReleased() throws {
        let foundationURL = try makeFoundationTemporaryFile(contents: Data([0xb1, 0xb2]))
        var ownership: LibraryOwnedTemporaryFile? = try LibraryOwnedTemporaryFile.adopt(foundationURL)
        let ownedURL = try #require(ownership?.url)

        #expect(FileManager.default.fileExists(atPath: ownedURL.path))
        ownership = nil
        #expect(FileManager.default.fileExists(atPath: ownedURL.path) == false)
    }
}

private struct DownloadPlan: Sendable {
    let body: Data
    let statusCode: Int
}

private actor ScriptedDownloadTransport: NetworkTransport {
    private let plans: [DownloadPlan]
    private var nextPlanIndex = 0
    private var files: [URL] = []
    private var attempts: [UInt] = []
    private var previousFilePresence: [Bool] = []

    init(_ plans: [DownloadPlan]) {
        self.plans = plans
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw DownloadExecutionTestError.unexpectedDataPath
    }

    func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        let currentIndex = nextPlanIndex
        nextPlanIndex += 1
        attempts.append(request.attemptNumber)
        if let previousURL = files.last {
            previousFilePresence.append(FileManager.default.fileExists(atPath: previousURL.path))
        }

        guard plans.indices.contains(currentIndex) else {
            return .failure(
                error: DownloadExecutionTestError.unexpectedDownloadAttempt,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        let plan = plans[currentIndex]
        progress.startAttempt(attemptNumber: request.attemptNumber, expectedBytesToSend: nil)
        do {
            let foundationURL = try makeFoundationTemporaryFile(contents: plan.body)
            let ownership = try LibraryOwnedTemporaryFile.adopt(foundationURL)
            files.append(ownership.url)
            progress.updateDownload(
                bytesReceived: Int64(plan.body.count),
                expectedBytesToReceive: Int64(plan.body.count),
            )
            return .success(
                file: ownership,
                response: HTTPResponse(status: .init(code: plan.statusCode)),
                rawTaskMetrics: nil,
            )
        } catch {
            return .failure(error: error, rawTaskMetrics: nil, didStartTask: true)
        }
    }

    func createdFileURLs() -> [URL] {
        files
    }

    func previousFilePresenceAtAttemptStarts() -> [Bool] {
        previousFilePresence
    }

    func attemptNumbers() -> [UInt] {
        attempts
    }

    func executionCount() -> Int {
        attempts.count
    }
}

private enum DownloadRecoveryStep: Sendable {
    case replay
    case doNotReplay
    case failure
    case suspend
}

private actor DownloadAuthenticationScript {
    private let steps: [DownloadRecoveryStep]
    private var nextStepIndex = 0
    private var contexts: [AuthenticationRecoveryContext] = []
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ steps: [DownloadRecoveryStep]) {
        self.steps = steps
    }

    func record(_ context: AuthenticationRecoveryContext) {
        contexts.append(context)
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func nextRecovery() async throws -> AuthenticationRecovery {
        guard steps.indices.contains(nextStepIndex) else {
            return .doNotReplay
        }

        let step = steps[nextStepIndex]
        nextStepIndex += 1

        switch step {
        case .replay:
            return .replay
        case .doNotReplay:
            return .doNotReplay
        case .failure:
            throw DownloadExecutionTestError.recoveryFailed
        case .suspend:
            try await Task.sleep(for: .seconds(3_600))
            return .doNotReplay
        }
    }

    func recordedContexts() -> [AuthenticationRecoveryContext] {
        contexts
    }

    func waitUntilRecoveryStarts() async {
        guard contexts.isEmpty else {
            return
        }

        await withCheckedContinuation { recoveryWaiters.append($0) }
    }
}

private struct ScriptedDownloadAuthenticationProvider: AuthenticationProvider {
    let script: DownloadAuthenticationScript

    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        context.request
    }

    func recover(_ context: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        await script.record(context)
        return try await script.nextRecovery()
    }
}

private struct DownloadFileObservation: Sendable, Equatable {
    let url: URL
    let existsDuringCallback: Bool
    let bodyDuringCallback: Data?
}

private final class ValidationFileRecorder: Sendable {
    private let storage = Mutex<[DownloadFileObservation]>([])

    func record(_ observation: DownloadFileObservation) {
        storage.withLock { $0.append(observation) }
    }

    func values() -> [DownloadFileObservation] {
        storage.withLock { $0 }
    }
}

private struct RetrySleepObservation: Sendable, Equatable {
    let delay: Duration
    let previousWasRemoved: Bool
}

private enum DownloadExecutionTestError: Error, Sendable, Equatable {
    case unexpectedDataPath
    case unexpectedDownloadAttempt
    case recoveryFailed
}

private func waitForRemoval(of url: URL) async {
    for _ in 0 ..< 100 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func makeDownloadEndpoint() throws -> Endpoint<Never, Never, DownloadedFile> {
    let url = try #require(URL(string: "https://download.test/response"))
    return Endpoint<Never, Never, DownloadedFile>.download(
        method: .get,
        route: .absolute(url),
    )
}

private func fileURL(in body: ReceivedResponseBody) -> URL? {
    guard case let .file(url) = body else {
        return nil
    }

    return url
}

private func makeFoundationTemporaryFile(contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-networking-foundation-download-\(UUID().uuidString)",
    )
    try contents.write(to: url)
    return url
}
