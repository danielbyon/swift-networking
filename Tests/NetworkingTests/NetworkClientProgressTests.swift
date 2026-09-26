//
//  NetworkClientProgressTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Testing
@testable import Networking

struct NetworkClientProgressTests {
    @Test("Retry attempts reset byte counters and logical completion follows decoding")
    func retryAttemptsResetProgressBeforeSuccessfulCompletion() async throws {
        let gate = AttemptProgressGate()
        let transport = ProgressReportingTransport(
            steps: [
                ProgressTransportStep(
                    result: .success(
                        data: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
                        response: HTTPResponse(status: .init(code: 503)),
                        rawTaskMetrics: nil,
                    ),
                    bytesSent: 3,
                    expectedBytesToSend: 3,
                    bytesReceived: 5,
                    expectedBytesToReceive: 5,
                ),
                ProgressTransportStep(
                    result: .success(
                        data: Data([0x2a]),
                        response: HTTPResponse(status: .init(code: 200)),
                        rawTaskMetrics: nil,
                    ),
                    bytesSent: 1,
                    expectedBytesToSend: 3,
                    bytesReceived: 1,
                    expectedBytesToReceive: 1,
                ),
            ],
            gate: gate,
        )
        var retryConfiguration = RetryPolicy.Configuration()
        retryConfiguration.maximumRetries = 1
        retryConfiguration.backoffStrategy = .immediate
        retryConfiguration.retryableMethods = [.post]
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withRetryPolicy(RetryPolicy(configuration: retryConfiguration)),
        )
        let bodyfulRequest = try makeBodyfulRequest()
        let task = client.task(for: bodyfulRequest)

        await gate.waitUntilReported(1)
        var iterator = task.progress.makeAsyncIterator()
        let firstAttempt = try #require(await iterator.next())
        #expect(firstAttempt.attemptNumber == 1)
        #expect(firstAttempt.bytesSent == 3)
        #expect(firstAttempt.bytesReceived == 5)
        #expect(firstAttempt.isComplete == false)

        await gate.release(1)
        await gate.waitUntilReported(2)
        let secondAttempt = try #require(await iterator.next())
        #expect(secondAttempt.attemptNumber == 2)
        #expect(secondAttempt.bytesSent == 1)
        #expect(secondAttempt.bytesReceived == 1)
        #expect(secondAttempt.expectedBytesToSend == 3)
        #expect(secondAttempt.expectedBytesToReceive == 1)
        #expect(secondAttempt.isComplete == false)

        await gate.release(2)
        let response = try await task.value
        let terminal = try #require(await iterator.next())
        #expect(response.value == Data([0x2a]))
        #expect(response.attempts.map(\.attemptNumber) == [1, 2])
        #expect(response.attempts.map(\.outcome) == [.retryScheduled, .acceptedResponse])
        #expect(terminal.isComplete)
        #expect(terminal.attemptNumber == 2)
        #expect(terminal.bytesSent == 1)
        #expect(terminal.bytesReceived == 1)
        #expect(await iterator.next() == nil)
    }

    @Test("Authentication replay starts a new progress attempt")
    func authenticationReplayResetsProgressCounters() async throws {
        let gate = AttemptProgressGate()
        let transport = ProgressReportingTransport(
            steps: [
                ProgressTransportStep(
                    result: .success(
                        data: Data([0xaa, 0xbb]),
                        response: HTTPResponse(status: .init(code: 401)),
                        rawTaskMetrics: nil,
                    ),
                    bytesSent: 3,
                    expectedBytesToSend: 3,
                    bytesReceived: 2,
                    expectedBytesToReceive: 2,
                ),
                ProgressTransportStep(
                    result: .success(
                        data: Data([0x42]),
                        response: HTTPResponse(status: .init(code: 200)),
                        rawTaskMetrics: nil,
                    ),
                    bytesSent: 2,
                    expectedBytesToSend: 3,
                    bytesReceived: 1,
                    expectedBytesToReceive: 1,
                ),
            ],
            gate: gate,
        )
        let url = try #require(URL(string: "https://progress.test/auth"))
        let endpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(url),
            body: .data(),
            response: .data,
        )
        .authenticationRequirement(.required(maximumReplays: 1))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(AlwaysReplayAuthenticationProvider()),
        )
        let task = client.task(for: Request(endpoint: endpoint, body: Data([0x01, 0x02, 0x03])))

        await gate.waitUntilReported(1)
        var iterator = task.progress.makeAsyncIterator()
        let firstAttempt = try #require(await iterator.next())
        #expect(firstAttempt.attemptNumber == 1)
        #expect(firstAttempt.bytesReceived == 2)

        await gate.release(1)
        await gate.waitUntilReported(2)
        let replayAttempt = try #require(await iterator.next())
        #expect(replayAttempt.attemptNumber == 2)
        #expect(replayAttempt.bytesSent == 2)
        #expect(replayAttempt.bytesReceived == 1)
        #expect(replayAttempt.isComplete == false)

        await gate.release(2)
        let response = try await task.value
        let terminal = try #require(await iterator.next())
        #expect(response.value == Data([0x42]))
        #expect(response.attempts.map(\.outcome) == [.authenticationReplayScheduled, .acceptedResponse])
        #expect(terminal.attemptNumber == 2)
        #expect(terminal.isComplete)
    }

    @Test("Decoder failure after complete byte transfer never publishes successful completion")
    func decoderFailureLeavesProgressNonterminal() async throws {
        let gate = AttemptProgressGate()
        let transport = ProgressReportingTransport(
            steps: [
                ProgressTransportStep(
                    result: .success(
                        data: Data([0x10, 0x20, 0x30]),
                        response: HTTPResponse(status: .init(code: 200)),
                        rawTaskMetrics: nil,
                    ),
                    bytesSent: 0,
                    expectedBytesToSend: 0,
                    bytesReceived: 3,
                    expectedBytesToReceive: 3,
                ),
            ],
            gate: gate,
        )
        let url = try #require(URL(string: "https://progress.test/decode-failure"))
        let decoder = ResponseDecoding<String>.custom { _, _ in
            throw NetworkProgressClientTestError.expectedFailure
        }
        let endpoint = Endpoint<Never, Never, String>.data(
            method: .get,
            route: .absolute(url),
            response: decoder,
        )
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: Request(endpoint: endpoint))

        await gate.waitUntilReported(1)
        var iterator = task.progress.makeAsyncIterator()
        let transferred = try #require(await iterator.next())
        #expect(transferred.bytesReceived == 3)
        #expect(transferred.expectedBytesToReceive == 3)
        #expect(transferred.downloadFractionCompleted == 1)
        #expect(transferred.isComplete == false)

        await gate.release(1)
        do {
            _ = try await task.value
            Issue.record("Expected the response decoder to fail")
        } catch is NetworkProgressClientTestError {
            // A complete transfer is still nonterminal until response decoding succeeds.
        }
        #expect(await iterator.next() == nil)
        var lateIterator = task.progress.makeAsyncIterator()
        #expect(await lateIterator.next() == nil)
    }

    private func makeBodyfulRequest() throws -> Request<Data> {
        let url = try #require(URL(string: "https://progress.test/retry"))
        let endpoint = Endpoint<Never, Data, Data>.data(
            method: .post,
            route: .absolute(url),
            body: .data(),
            response: .data,
        )
        return Request(endpoint: endpoint, body: Data([0x01, 0x02, 0x03]))
    }
}

private struct ProgressTransportStep: Sendable {
    let result: NetworkTransportResult
    let bytesSent: Int64
    let expectedBytesToSend: Int64?
    let bytesReceived: Int64
    let expectedBytesToReceive: Int64?
}

private actor ProgressReportingTransport: NetworkTransport {
    private var steps: [ProgressTransportStep]
    private let gate: AttemptProgressGate

    init(steps: [ProgressTransportStep], gate: AttemptProgressGate) {
        self.steps = steps
        self.gate = gate
    }

    func execute(_: TransportRequest) async throws -> (Data, HTTPResponse) {
        throw NetworkProgressClientTestError.unexpectedLegacyTransportCall
    }

    func executeWithMetrics(_: TransportRequest) async -> NetworkTransportResult {
        .failure(
            error: NetworkProgressClientTestError.unexpectedLegacyTransportCall,
            rawTaskMetrics: nil,
            didStartTask: false,
        )
    }

    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        let step = steps.removeFirst()
        progress.startAttempt(
            attemptNumber: request.attemptNumber,
            expectedBytesToSend: step.expectedBytesToSend,
        )
        progress.updateUpload(
            bytesSent: step.bytesSent,
            expectedBytesToSend: step.expectedBytesToSend,
        )
        progress.updateDownload(
            bytesReceived: step.bytesReceived,
            expectedBytesToReceive: step.expectedBytesToReceive,
        )
        await gate.reportAndWait(request.attemptNumber)
        return step.result
    }
}

private actor AttemptProgressGate {
    private var reportedAttempts: Set<UInt> = []
    private var releasedAttempts: Set<UInt> = []
    private var reportWaiters: [UInt: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [UInt: [CheckedContinuation<Void, Never>]] = [:]

    init() {}

    func reportAndWait(_ attempt: UInt) async {
        reportedAttempts.insert(attempt)
        resume(reportWaiters.removeValue(forKey: attempt) ?? [])
        guard releasedAttempts.contains(attempt) == false else {
            return
        }

        await withCheckedContinuation { releaseWaiters[attempt, default: []].append($0) }
    }

    func waitUntilReported(_ attempt: UInt) async {
        guard reportedAttempts.contains(attempt) == false else {
            return
        }

        await withCheckedContinuation { reportWaiters[attempt, default: []].append($0) }
    }

    func release(_ attempt: UInt) {
        releasedAttempts.insert(attempt)
        resume(releaseWaiters.removeValue(forKey: attempt) ?? [])
    }

    private func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct AlwaysReplayAuthenticationProvider: AuthenticationProvider {
    func adapt(_ context: RequestAdaptationContext) async throws -> HTTPRequest {
        context.request
    }

    func recover(_: AuthenticationRecoveryContext) async throws -> AuthenticationRecovery {
        .replay
    }
}

private enum NetworkProgressClientTestError: Error {
    case expectedFailure
    case unexpectedLegacyTransportCall
}
