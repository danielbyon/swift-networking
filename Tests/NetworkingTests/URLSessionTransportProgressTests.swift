//
//  URLSessionTransportProgressTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Synchronization
import Testing
@testable import Networking

struct URLSessionTransportProgressTests {
    @Test("Concurrent data and upload tasks keep shared-session delegate state isolated")
    func concurrentTasksDoNotCrossRouteProgressResponsesRedirectsOrMetrics() async throws {
        let dataURL = try #require(URL(string: "https://progress.test/redirect"))
        let redirectedURL = try #require(URL(string: "https://progress.test/data-final"))
        let uploadURL = try #require(URL(string: "https://progress.test/upload"))
        let dataBody = Data([0xa1, 0xa2, 0xa3, 0xa4])
        let uploadResponseBody = Data([0xb1, 0xb2, 0xb3])
        ProgressURLProtocol.install(
            .redirect(redirectedURL),
            for: dataURL.path,
        )
        ProgressURLProtocol.install(
            .response(uploadResponseBody),
            for: redirectedURL.path,
        )
        ProgressURLProtocol.install(
            .response(Data([0xc1, 0xc2])),
            for: uploadURL.path,
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let dataTask = client.task(for: makeProgressDataRequest(dataURL))
        let uploadTask = client.task(for: makeProgressUploadRequest(uploadURL, body: dataBody))

        async let dataResponse = dataTask.value
        async let uploadResponse = uploadTask.value
        let (dataResult, uploadResult) = try await (dataResponse, uploadResponse)

        #expect(dataResult.value == uploadResponseBody)
        #expect(uploadResult.value == Data([0xc1, 0xc2]))
        #expect(dataResult.requestID == dataTask.requestID)
        #expect(uploadResult.requestID == uploadTask.requestID)
        #expect(dataResult.attempts.count == 1)
        #expect(uploadResult.attempts.count == 1)
        #expect(dataResult.attempts.first?.requestID == dataTask.requestID)
        #expect(uploadResult.attempts.first?.requestID == uploadTask.requestID)
        #expect(dataResult.attempts.first?.attemptNumber == 1)
        #expect(uploadResult.attempts.first?.attemptNumber == 1)

        let dataProgress = await terminalProgress(for: dataTask)
        let uploadProgress = await terminalProgress(for: uploadTask)
        #expect(dataProgress?.attemptNumber == 1)
        #expect(dataProgress?.isComplete == true)
        #expect(dataProgress?.bytesReceived == Int64(uploadResponseBody.count))
        #expect(uploadProgress?.attemptNumber == 1)
        #expect(uploadProgress?.isComplete == true)
        #expect(uploadProgress?.bytesSent == 0)
        #expect(uploadProgress?.expectedBytesToSend == Int64(dataBody.count))
        #expect(uploadProgress?.bytesReceived == Int64(uploadResult.value.count))

        let dataMetrics = try #require(dataResult.attempts.first?.rawTaskMetrics)
        #expect(dataMetrics.redirectCount == 1)
        #expect(dataMetrics.transactionMetrics.contains {
            $0.request.url?.path == redirectedURL.path
        })
        #expect(dataMetrics.transactionMetrics.allSatisfy {
            $0.request.url?.host == "progress.test"
        })
        let uploadMetrics = try #require(uploadResult.attempts.first?.rawTaskMetrics)
        #expect(uploadMetrics.redirectCount == 0)
        #expect(uploadMetrics.transactionMetrics.contains {
            $0.request.url?.path == uploadURL.path
        })
        #expect(uploadMetrics.transactionMetrics.allSatisfy {
            $0.request.url?.path == uploadURL.path
        })
    }

    @Test("Cancelling a shared task cancels its suspended URLSession operation")
    func cancellingNetworkTaskCancelsUnderlyingURLSessionTask() async throws {
        let url = try #require(URL(string: "https://progress.test/stall"))
        let gate = URLProtocolGate()
        ProgressURLProtocol.install(.stall(gate), for: url.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = client.task(for: makeProgressDataRequest(url))
        await gate.waitUntilStarted()
        task.cancel()
        await gate.waitUntilStopped()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to finish the shared task")
        } catch is CancellationError {
            // Explicit NetworkTask cancellation is preserved for value awaiters.
        }

        var lateIterator = task.progress.makeAsyncIterator()
        #expect(await lateIterator.next() == nil)
    }

    @Test("Shared delegate routes upload progress and redirect decisions by task identifier")
    func sharedDelegateRoutesAttemptCallbacksByTaskIdentifier() async throws {
        let firstURL = try #require(URL(string: "https://progress.test/first"))
        let secondURL = try #require(URL(string: "https://progress.test/second"))
        let redirectURL = try #require(URL(string: "https://progress.test/redirected"))
        let session = URLSession(configuration: .ephemeral)
        let firstTask = session.dataTask(with: firstURL)
        let secondTask = session.dataTask(with: secondURL)
        let firstCoordinator = NetworkProgressCoordinator()
        let secondCoordinator = NetworkProgressCoordinator()
        let firstReporter = firstCoordinator.reporter
        let secondReporter = secondCoordinator.reporter
        firstReporter.startAttempt(attemptNumber: 1, expectedBytesToSend: 17)
        secondReporter.startAttempt(attemptNumber: 1, expectedBytesToSend: 29)
        var firstIterator = firstCoordinator.progress.makeAsyncIterator()
        var secondIterator = secondCoordinator.progress.makeAsyncIterator()
        _ = await firstIterator.next()
        _ = await secondIterator.next()

        let firstRequest = TransportRequest(
            httpRequest: HTTPRequest(method: .post, url: firstURL),
            body: .none,
            redirectPolicy: .follow,
            requestID: RequestID(rawValue: UUID()),
        )
        let secondRequest = TransportRequest(
            httpRequest: HTTPRequest(method: .post, url: secondURL),
            body: .none,
            redirectPolicy: .reject,
            requestID: RequestID(rawValue: UUID()),
        )
        let router = URLSessionDelegateRouter()
        router.register(
            URLSessionTaskMetricsDelegate(
                transportRequest: firstRequest,
                initialRequest: URLRequest(url: firstURL),
                progressReporter: firstReporter,
            ),
            for: firstTask.taskIdentifier,
        )
        router.register(
            URLSessionTaskMetricsDelegate(
                transportRequest: secondRequest,
                initialRequest: URLRequest(url: secondURL),
                progressReporter: secondReporter,
            ),
            for: secondTask.taskIdentifier,
        )

        router.urlSession(
            session,
            task: firstTask,
            didSendBodyData: 7,
            totalBytesSent: 7,
            totalBytesExpectedToSend: 17,
        )
        router.urlSession(
            session,
            task: secondTask,
            didSendBodyData: 11,
            totalBytesSent: 11,
            totalBytesExpectedToSend: 29,
        )

        let redirectResponse = try #require(HTTPURLResponse(
            url: firstURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString],
        ))
        var firstRedirectRequest: URLRequest?
        var secondRedirectRequest: URLRequest?
        router.urlSession(
            session,
            task: firstTask,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: URLRequest(url: redirectURL),
            completionHandler: { firstRedirectRequest = $0 },
        )
        router.urlSession(
            session,
            task: secondTask,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: URLRequest(url: redirectURL),
            completionHandler: { secondRedirectRequest = $0 },
        )

        #expect(await firstIterator.next()?.bytesSent == 7)
        #expect(await secondIterator.next()?.bytesSent == 11)
        #expect(firstRedirectRequest?.url == redirectURL)
        #expect(secondRedirectRequest == nil)
        session.invalidateAndCancel()
    }

    private func terminalProgress(for task: NetworkTask<Data>) async -> NetworkProgress? {
        var iterator = task.progress.makeAsyncIterator()
        return await iterator.next()
    }

    private func makeProgressDataRequest(_ url: URL) -> Request<Data> {
        let endpoint = Endpoint<Never, Never, Data>.data(
            method: .get,
            route: .absolute(url),
            response: .data,
        )
        return Request(endpoint: endpoint)
    }

    private func makeProgressUploadRequest(_ url: URL, body: Data) -> Request<Data> {
        let endpoint = Endpoint<Never, Data, Data>.upload(
            method: .post,
            route: .absolute(url),
            body: .data(),
            response: .data,
        )
        return Request(endpoint: endpoint, body: body)
    }
}

private struct ProgressURLProtocolPlan: Sendable {
    enum Action: Sendable {
        case response(Data)
        case redirect(URL)
        case stall(URLProtocolGate)
    }

    let action: Action
}

private final class ProgressURLProtocol: URLProtocol {
    private static let plans = Mutex<[String: ProgressURLProtocolPlan]>([:])
    private static let cancellationGates = Mutex<[String: URLProtocolGate]>([:])

    static func install(_ action: ProgressURLProtocolPlan.Action, for path: String) {
        plans.withLock { $0[path] = ProgressURLProtocolPlan(action: action) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "progress.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let plan = Self.plans.withLock({ $0.removeValue(forKey: url.path) })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch plan.action {
        case let .redirect(destination):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString],
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destination),
                redirectResponse: response,
            )
        case let .response(data):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)],
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let firstChunkCount = data.count / 2
            let firstChunk = Data(data.prefix(firstChunkCount))
            let secondChunk = Data(data.dropFirst(firstChunkCount))
            if !firstChunk.isEmpty {
                client?.urlProtocol(self, didLoad: firstChunk)
            }
            if !secondChunk.isEmpty {
                client?.urlProtocol(self, didLoad: secondChunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .stall(gate):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "10"],
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            Self.cancellationGates.withLock { $0[url.path] = gate }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0xdd]))
            Task { await gate.markStarted() }
        }
    }

    override func stopLoading() {
        guard let path = request.url?.path,
              let gate = Self.cancellationGates.withLock({ $0.removeValue(forKey: path) })
        else {
            return
        }

        Task { await gate.markStopped() }
    }
}

private actor URLProtocolGate {
    private var started = false
    private var stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        resume(&startWaiters)
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }

        await withCheckedContinuation { startWaiters.append($0) }
    }

    func markStopped() {
        stopped = true
        resume(&stopWaiters)
    }

    func waitUntilStopped() async {
        guard !stopped else {
            return
        }

        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
