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
    @Test("Concurrent data, upload, and download tasks keep shared-session delegate state isolated")
    func concurrentTasksDoNotCrossRouteProgressResponsesRedirectsOrMetrics() async throws {
        let dataURL = try #require(URL(string: "https://progress.test/redirect"))
        let redirectedURL = try #require(URL(string: "https://progress.test/data-final"))
        let uploadURL = try #require(URL(string: "https://progress.test/upload"))
        let downloadURL = try #require(URL(string: "https://progress.test/download-concurrent"))
        let dataBody = Data([0xa1, 0xa2, 0xa3, 0xa4])
        let uploadResponseBody = Data([0xb1, 0xb2, 0xb3])
        let downloadResponseBody = Data([0xd1, 0xd2, 0xd3, 0xd4])
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
        ProgressURLProtocol.install(.response(downloadResponseBody), for: downloadURL.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let dataTask = client.task(for: makeProgressDataRequest(dataURL))
        let uploadTask = client.task(for: makeProgressUploadRequest(uploadURL, body: dataBody))
        let downloadTask = client.task(for: makeProgressDownloadRequest(downloadURL))

        async let dataResponse = dataTask.value
        async let uploadResponse = uploadTask.value
        async let downloadResponse = downloadTask.value
        let (dataResult, uploadResult, downloadResult) = try await (
            dataResponse,
            uploadResponse,
            downloadResponse,
        )

        #expect(dataResult.value == uploadResponseBody)
        #expect(uploadResult.value == Data([0xc1, 0xc2]))
        let downloadedBytes = try Data(contentsOf: downloadResult.value.ownership.url)
        #expect(downloadedBytes == downloadResponseBody)
        #expect(dataResult.requestID == dataTask.requestID)
        #expect(uploadResult.requestID == uploadTask.requestID)
        #expect(downloadResult.requestID == downloadTask.requestID)
        #expect(dataResult.attempts.count == 1)
        #expect(uploadResult.attempts.count == 1)
        #expect(downloadResult.attempts.count == 1)
        #expect(dataResult.attempts.first?.requestID == dataTask.requestID)
        #expect(uploadResult.attempts.first?.requestID == uploadTask.requestID)
        #expect(downloadResult.attempts.first?.requestID == downloadTask.requestID)
        #expect(dataResult.attempts.first?.attemptNumber == 1)
        #expect(uploadResult.attempts.first?.attemptNumber == 1)
        #expect(downloadResult.attempts.first?.attemptNumber == 1)

        let dataProgress = await terminalProgress(for: dataTask)
        let uploadProgress = await terminalProgress(for: uploadTask)
        let downloadProgress = await terminalProgress(for: downloadTask)
        #expect(dataProgress?.attemptNumber == 1)
        #expect(dataProgress?.isComplete == true)
        #expect(dataProgress?.bytesReceived == Int64(uploadResponseBody.count))
        #expect(uploadProgress?.attemptNumber == 1)
        #expect(uploadProgress?.isComplete == true)
        #expect(uploadProgress?.bytesSent == 0)
        #expect(uploadProgress?.expectedBytesToSend == Int64(dataBody.count))
        #expect(uploadProgress?.bytesReceived == Int64(uploadResult.value.count))
        #expect(downloadProgress?.attemptNumber == 1)
        #expect(downloadProgress?.isComplete == true)
        #expect(downloadProgress?.bytesReceived == Int64(downloadResponseBody.count))

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
        let downloadMetrics = try #require(downloadResult.attempts.first?.rawTaskMetrics)
        #expect(downloadMetrics.redirectCount == 0)
        #expect(downloadMetrics.transactionMetrics.contains {
            $0.request.url?.path == downloadURL.path
        })
        downloadResult.value.ownership.discard()
    }

    @Test("URLSession download tasks adopt completed files and report download delegate progress")
    func downloadTaskAdoptsFileAndReportsProgress() async throws {
        let url = try #require(URL(string: "https://progress.test/download"))
        let payload = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        ProgressURLProtocol.install(.response(payload), for: url.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: makeProgressDownloadRequest(url))

        let response = try await task.value
        let fileURL = response.value.ownership.url
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(fileURL.deletingLastPathComponent() == FileManager.default.temporaryDirectory)
        #expect(fileURL.lastPathComponent.hasPrefix("swift-networking-download-"))
        let downloadedBytes = try Data(contentsOf: fileURL)
        #expect(downloadedBytes == payload)
        #expect(response.retainedBody == nil)
        #expect(response.attempts.map(\.outcome) == [.acceptedResponse])
        #expect(response.attempts.first?.rawTaskMetrics?.transactionMetrics.contains {
            $0.request.url?.path == url.path
        } == true)

        var iterator = task.progress.makeAsyncIterator()
        let terminalProgress = try #require(await iterator.next())
        #expect(terminalProgress.attemptNumber == 1)
        #expect(terminalProgress.isComplete)
        #expect(terminalProgress.bytesReceived == Int64(payload.count))
    }

    @Test("URLSession download tasks keep redirects and metrics within one attempt")
    func downloadRedirectStaysWithinAttemptAndCapturesMetrics() async throws {
        let url = try #require(URL(string: "https://progress.test/download-redirect"))
        let finalURL = try #require(URL(string: "https://progress.test/download-final"))
        let payload = Data([0xe1, 0xe2, 0xe3])
        ProgressURLProtocol.install(.redirect(finalURL), for: url.path)
        ProgressURLProtocol.install(.response(payload), for: finalURL.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: makeProgressDownloadRequest(url))

        let response = try await task.value
        let metrics = try #require(response.attempts.first?.rawTaskMetrics)

        #expect(response.attempts.map(\.attemptNumber) == [1])
        #expect(response.attempts.map(\.outcome) == [.acceptedResponse])
        #expect(metrics.redirectCount == 1)
        #expect(metrics.transactionMetrics.contains { $0.request.url?.path == url.path })
        #expect(metrics.transactionMetrics.contains { $0.request.url?.path == finalURL.path })
        let downloadedBytes = try Data(contentsOf: response.value.ownership.url)
        #expect(downloadedBytes == payload)

        response.value.ownership.discard()
    }

    @Test("URLSession download tasks preserve expected upload totals for an in-memory request body")
    func downloadRequestBodyKeepsUploadProgress() async throws {
        let url = try #require(URL(string: "https://progress.test/download-with-body"))
        let requestBody = Data([0xf1, 0xf2, 0xf3, 0xf4])
        let responseBody = Data([0xa4, 0xa5])
        ProgressURLProtocol.install(.response(responseBody), for: url.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport)
        let task = client.task(for: makeProgressDownloadRequest(url, body: requestBody))

        let response = try await task.value
        let progress = try #require(await terminalProgress(for: task))

        #expect(progress.attemptNumber == 1)
        #expect(progress.isComplete)
        #expect(progress.expectedBytesToSend == Int64(requestBody.count))
        #expect(progress.bytesReceived == Int64(responseBody.count))

        response.value.ownership.discard()
    }

    @Test("Cancelling a shared download task cancels its suspended URLSession operation")
    func cancellingDownloadTaskCancelsUnderlyingURLSessionTask() async throws {
        let url = try #require(URL(string: "https://progress.test/download-stall"))
        let gate = URLProtocolGate()
        ProgressURLProtocol.install(.stall(gate), for: url.path)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
        )
        let client = try NetworkClient(transport: transport, configuration: .init())
        let task = client.task(for: makeProgressDownloadRequest(url))
        await gate.waitUntilStarted()
        task.cancel()
        await gate.waitUntilStopped()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to finish the download task")
        } catch is CancellationError {
            // Explicit NetworkTask cancellation is preserved for value awaiters.
        }

        var lateIterator = task.progress.makeAsyncIterator()
        #expect(await lateIterator.next() == nil)
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

    @Test("Cancellation before URLSession resume finishes without publishing an attempt")
    func cancellationBeforeURLSessionStartDoesNotPublishAnAttempt() async throws {
        let url = try #require(URL(string: "https://progress.test/before-start"))
        let startGate = URLSessionStartGate()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProgressURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: .init(),
            sessionConfiguration: sessionConfiguration,
            beforeTaskStart: { await startGate.waitBeforeStart() },
        )
        let coordinator = NetworkProgressCoordinator()
        var iterator = coordinator.progress.makeAsyncIterator()
        let request = TransportRequest(
            httpRequest: HTTPRequest(method: .get, url: url),
            body: .none,
            redirectPolicy: .follow,
            requestID: RequestID(rawValue: UUID()),
        )
        let transportTask = Task {
            await transport.executeWithMetrics(request, progress: coordinator.reporter)
        }

        await startGate.waitUntilReached()
        let initialProgress = await iterator.next()
        transportTask.cancel()
        await startGate.release()
        let result = await transportTask.value
        coordinator.finish(successfully: false)

        guard case let .failure(error, _, didStartTask) = result else {
            Issue.record("Expected URLSession cancellation before start")
            return
        }

        #expect(error is CancellationError)
        #expect(didStartTask == false)
        #expect(initialProgress?.attemptNumber == nil)
        #expect(await iterator.next() == nil)
    }

    @Test("Shared delegate routes upload progress and redirect decisions by task identifier")
    func sharedDelegateRoutesAttemptCallbacksByTaskIdentifier() async throws {
        let firstURL = try #require(URL(string: "https://progress.test/first"))
        let secondURL = try #require(URL(string: "https://progress.test/second"))
        let downloadURL = try #require(URL(string: "https://progress.test/download-body"))
        let redirectURL = try #require(URL(string: "https://progress.test/redirected"))
        let requestBody = Data([0x18, 0x19, 0x1a])
        let session = URLSession(configuration: .ephemeral)
        let firstTask = session.dataTask(with: firstURL)
        let secondTask = session.dataTask(with: secondURL)
        let downloadTask = session.downloadTask(with: downloadURL)
        let firstCoordinator = NetworkProgressCoordinator()
        let secondCoordinator = NetworkProgressCoordinator()
        let downloadCoordinator = NetworkProgressCoordinator()
        let firstReporter = firstCoordinator.reporter
        let secondReporter = secondCoordinator.reporter
        let downloadReporter = downloadCoordinator.reporter
        firstReporter.startAttempt(attemptNumber: 1, expectedBytesToSend: 17)
        secondReporter.startAttempt(attemptNumber: 1, expectedBytesToSend: 29)
        downloadReporter.startAttempt(
            attemptNumber: 1,
            expectedBytesToSend: Int64(requestBody.count),
        )
        var firstIterator = firstCoordinator.progress.makeAsyncIterator()
        var secondIterator = secondCoordinator.progress.makeAsyncIterator()
        var downloadIterator = downloadCoordinator.progress.makeAsyncIterator()
        _ = await firstIterator.next()
        _ = await secondIterator.next()
        _ = await downloadIterator.next()

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
        let downloadRequest = TransportRequest(
            httpRequest: HTTPRequest(method: .post, url: downloadURL),
            body: .data(requestBody),
            redirectPolicy: .follow,
            requestID: RequestID(rawValue: UUID()),
            operation: .download,
            execution: .download(body: requestBody),
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
        router.register(
            URLSessionTaskMetricsDelegate(
                transportRequest: downloadRequest,
                initialRequest: URLRequest(url: downloadURL),
                progressReporter: downloadReporter,
            ),
            for: downloadTask.taskIdentifier,
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
        router.urlSession(
            session,
            task: downloadTask,
            didSendBodyData: Int64(requestBody.count),
            totalBytesSent: Int64(requestBody.count),
            totalBytesExpectedToSend: Int64(requestBody.count),
        )

        let redirectResponseCandidate = HTTPURLResponse(
            url: firstURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString],
        )
        let redirectResponse = try #require(redirectResponseCandidate)
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
        let downloadProgress = await downloadIterator.next()
        #expect(downloadProgress?.bytesSent == Int64(requestBody.count))
        #expect(downloadProgress?.expectedBytesToSend == Int64(requestBody.count))
        #expect(downloadProgress?.bytesReceived == 0)
        #expect(firstRedirectRequest?.url == redirectURL)
        #expect(secondRedirectRequest == nil)
        session.invalidateAndCancel()
    }

    private func terminalProgress(for task: NetworkTask<some Sendable>) async -> NetworkProgress? {
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

    private func makeProgressDownloadRequest(_ url: URL) -> Request<DownloadedFile> {
        let endpoint = Endpoint<Never, Never, DownloadedFile>.download(
            method: .get,
            route: .absolute(url),
        )
        return Request(endpoint: endpoint)
    }

    private func makeProgressDownloadRequest(_ url: URL, body: Data) -> Request<DownloadedFile> {
        let endpoint = Endpoint<Never, Data, DownloadedFile>.download(
            method: .post,
            route: .absolute(url),
            body: .data(contentType: "application/octet-stream"),
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

private actor URLSessionStartGate {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitBeforeStart() async {
        reached = true
        resume(reachedWaiters)
        reachedWaiters.removeAll()
        guard !released else {
            return
        }

        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else {
            return
        }

        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
        released = true
        resume(releaseWaiters)
        releaseWaiters.removeAll()
    }

    private func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters {
            waiter.resume()
        }
    }
}
