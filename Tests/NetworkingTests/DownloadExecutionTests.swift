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

    @Test("Default temporary downloads clean up unless the public URL is accessed")
    func temporaryDownloadCleanupTransfersOnURLAccess() async throws {
        let transport = ScriptedDownloadTransport([
            .init(body: Data([0xd1]), statusCode: 200),
            .init(body: Data([0xd2]), statusCode: 200),
        ])
        let client = try NetworkClient(transport: transport)

        var automaticallyRemoved: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        #expect(automaticallyRemoved != nil)
        let automaticallyRemovedURL = try #require(await transport.createdFileURLs().first)
        automaticallyRemoved = nil
        await waitForRemoval(of: automaticallyRemovedURL)
        #expect(FileManager.default.fileExists(atPath: automaticallyRemovedURL.path) == false)

        var callerOwned: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let callerOwnedURL = try #require(await transport.createdFileURLs().last)
        #expect(callerOwned?.url == callerOwnedURL)
        callerOwned = nil
        #expect(FileManager.default.fileExists(atPath: callerOwnedURL.path))
        try FileManager.default.removeItem(at: callerOwnedURL)
    }

    @Test("Initial destination finalization disarms the old temporary path")
    func finalizationDoesNotDeleteRecreatedTemporarySource() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe1]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-finalized-\(UUID().uuidString)")
        var response: Response<DownloadedFile>? = try await client.send(
            Request(endpoint: makeDownloadEndpoint())
                .downloadDestination(.file(destination)),
        )
        let source = try #require(await transport.createdFileURLs().first)

        #expect(source != destination)
        #expect(response?.attempts.count == 1)
        #expect(try Data(contentsOf: destination) == Data([0xe1]))
        try Data([0xef]).write(to: source)
        response = nil

        #expect(try Data(contentsOf: source) == Data([0xef]))
        #expect(try Data(contentsOf: destination) == Data([0xe1]))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A successful move disarms the old temporary path")
    func moveDoesNotDeleteRecreatedTemporarySource() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe2]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-moved-\(UUID().uuidString)")
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        try downloadedFile?.move(to: destination)
        try Data([0xee]).write(to: source)
        downloadedFile = nil

        #expect(try Data(contentsOf: source) == Data([0xee]))
        #expect(try Data(contentsOf: destination) == Data([0xe2]))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A destination with the same path but a different URL identity does not count as the source")
    func nonFileDestinationWithMatchingPathDoesNotSilentlySucceed() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe2]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)
        let destination = try #require(URL(string: "https://unrelated.example\(source.path)"))
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(destination.isFileURL == false)
        #expect(source.standardizedFileURL.path == destination.standardizedFileURL.path)
        #expect(source.standardizedFileURL != destination.standardizedFileURL)

        do {
            try downloadedFile?.move(to: destination)
            Issue.record("Expected a move to a non-file URL to fail")
        } catch let error as DownloadFileError {
            switch error {
            case let .moveFailed(failedSource, failedDestination, _):
                #expect(failedSource == source)
                #expect(failedDestination == destination)
            default:
                Issue.record("Expected moveFailed, received \(error)")
            }
        } catch {
            Issue.record("Expected DownloadFileError.moveFailed, received \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: source.path))
        downloadedFile = nil
        await waitForRemoval(of: source)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("Successful moves can be repeated from the current file location")
    func successfulMovesCanBeRepeated() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe2]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let firstDestination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-first-move-\(UUID().uuidString)")
        let secondDestination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-second-move-\(UUID().uuidString)")
        let downloadedFile = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        try downloadedFile.move(to: firstDestination)
        #expect(downloadedFile.url == firstDestination)
        try downloadedFile.move(to: secondDestination)
        #expect(downloadedFile.url == secondDestination)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(FileManager.default.fileExists(atPath: firstDestination.path) == false)
        #expect(try Data(contentsOf: secondDestination) == Data([0xe2]))
        try FileManager.default.removeItem(at: secondDestination)
    }

    @Test("A fixed destination collision preserves the caller file")
    func fixedDestinationCollisionPreservesCallerFile() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe3]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-finalization-collision-\(UUID().uuidString)")
        let originalContents = Data([0xfa])
        try originalContents.write(to: destination)
        let request = try Request<DownloadedFile>(endpoint: makeDownloadEndpoint())
            .downloadDestination(.file(destination))
        let task = client.task(for: request)
        var progressIterator = task.progress.makeAsyncIterator()

        var receivedExpectedError = false
        do {
            _ = try await task.value
            Issue.record("Expected finalization onto an existing file to fail")
        } catch let error as DownloadFileError {
            if case let .finalizationFailed(_, errorDestination, _) = error {
                receivedExpectedError = true
                #expect(errorDestination == destination)
            } else {
                Issue.record("Unexpected download file error: \(error)")
            }
        } catch {
            Issue.record("Unexpected finalization error: \(error)")
        }

        #expect(receivedExpectedError)
        while let progress = await progressIterator.next() {
            #expect(progress.isComplete == false)
        }
        #expect(await transport.executionCount() == 1)
        #expect(try Data(contentsOf: destination) == originalContents)
        let source = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A failed move preserves the current URL and existing destination")
    func failedMovePreservesCurrentURLAndDestination() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe3]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-move-collision-\(UUID().uuidString)")
        try Data([0xfa]).write(to: destination)
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        var receivedExpectedError = false
        do {
            try downloadedFile?.move(to: destination)
            Issue.record("Expected moving onto an existing file to fail")
        } catch let error as DownloadFileError {
            if case let .moveFailed(errorSource, errorDestination, _) = error {
                receivedExpectedError = true
                #expect(errorSource == source)
                #expect(errorDestination == destination)
            } else {
                Issue.record("Unexpected download file error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error from failed move: \(error)")
        }

        #expect(receivedExpectedError)
        #expect(downloadedFile?.url == source)
        #expect(try Data(contentsOf: destination) == Data([0xfa]))
        downloadedFile = nil
        #expect(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A failed move keeps automatic cleanup armed for an untouched temporary download")
    func failedMoveStillCleansTemporarySourceOnRelease() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe4]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-failed-move-\(UUID().uuidString)")
        try Data([0xfb]).write(to: destination)
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        do {
            try downloadedFile?.move(to: destination)
            Issue.record("Expected moving onto an existing file to fail")
        } catch is DownloadFileError {
            // A failed move must leave automatic cleanup armed.
        }
        downloadedFile = nil

        await waitForRemoval(of: source)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try Data(contentsOf: destination) == Data([0xfb]))
        try FileManager.default.removeItem(at: destination)
    }

    @Test("Removal is idempotent and deinitialization preserves a recreated path")
    func removalDisarmsCleanupForRecreatedPath() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe5]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        try downloadedFile?.remove()
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        try downloadedFile?.remove()
        #expect(downloadedFile?.url == source)
        try Data([0xec]).write(to: source)
        downloadedFile = nil

        #expect(try Data(contentsOf: source) == Data([0xec]))
        try FileManager.default.removeItem(at: source)
    }

    @Test("A removal failure reports the current file URL")
    func removeFailureReportsCurrentURL() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-remove-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.bin")
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe5]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let downloadedFile = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        try downloadedFile.move(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        var receivedExpectedError = false
        do {
            try downloadedFile.remove()
            Issue.record("Expected removal in a read-only directory to fail")
        } catch let error as DownloadFileError {
            if case let .removeFailed(errorURL, _) = error {
                receivedExpectedError = true
                #expect(errorURL == destination)
            } else {
                Issue.record("Unexpected download file error: \(error)")
            }
        }

        #expect(receivedExpectedError)
        #expect(downloadedFile.url == destination)
    }

    @Test("Resolved destinations run once after authentication, retry, validation, and request copies")
    func resolvedDestinationRunsAfterAcceptedFinalResponse() async throws {
        let transport = ScriptedDownloadTransport([
            .init(body: Data([0x11]), statusCode: 401),
            .init(body: Data([0x22]), statusCode: 503),
            .init(body: Data([0x33]), statusCode: 200),
        ])
        let resolver = DownloadDestinationResolverRecorder()
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-resolved-\(UUID().uuidString)")
        let recovery = DownloadAuthenticationScript([.replay])
        let endpoint = try makeDownloadEndpoint().authenticationRequirement(.required(maximumReplays: 1))
        let client = try NetworkClient(
            transport: transport,
            configuration: .init().withAuthenticationProvider(
                ScriptedDownloadAuthenticationProvider(script: recovery),
            ),
        )
        let request = Request(endpoint: endpoint)
            .downloadDestination(.resolved(collisionPolicy: .failIfExists) { response, context in
                resolver.record(
                    DownloadDestinationResolutionObservation(
                        statusCode: response.status.code,
                        contextValue: context[DownloadDestinationContextKey.self],
                        destinationExisted: FileManager.default.fileExists(atPath: destination.path),
                    ),
                )
                return destination
            })
            .context(DownloadDestinationContextKey.self, value: "issue-19")
            .queryItems([URLQueryItem(name: "page", value: "1")])
            .headers(HTTPFields())
            .header(.accept, "application/octet-stream")
            .validationPolicy(.successfulStatusCodes)
            .successfulResponseBodyRetentionPolicy(.none)
            .validationErrorBodyRetentionPolicy(.none)
            .retryPolicy(RetryPolicy())
            .retryPolicy { $0.maximumRetries = 1 }
            .redirectPolicy(.follow)

        let response = try await client.send(request)
        let files = await transport.createdFileURLs()

        #expect(await transport.attemptNumbers() == [1, 2, 3])
        #expect(await transport.previousFilePresenceAtAttemptStarts() == [false, false])
        #expect(await recovery.recordedContexts().count == 1)
        #expect(resolver.values() == [
            DownloadDestinationResolutionObservation(
                statusCode: 200,
                contextValue: "issue-19",
                destinationExisted: false,
            ),
        ])
        #expect(files.count == 3)
        #expect(FileManager.default.fileExists(atPath: files[0].path) == false)
        #expect(FileManager.default.fileExists(atPath: files[1].path) == false)
        #expect(response.value.url == destination)
        #expect(response.retainedBody == nil)
        #expect(try Data(contentsOf: destination) == Data([0x33]))
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A rejected response never resolves or touches a caller destination")
    func rejectedDownloadDoesNotResolveDestination() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe6]), statusCode: 200)])
        let resolver = DownloadDestinationResolverRecorder()
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-rejected-\(UUID().uuidString)")
        let validation = ResponseValidationPolicy.custom { _ in .reject(reason: "rejected for test") }
        let client = try NetworkClient(transport: transport)
        let request = try Request<DownloadedFile>(endpoint: makeDownloadEndpoint())
            .downloadDestination(.resolved(collisionPolicy: .failIfExists) { _, _ in
                resolver.record(
                    DownloadDestinationResolutionObservation(
                        statusCode: 0,
                        contextValue: nil,
                        destinationExisted: FileManager.default.fileExists(atPath: destination.path),
                    ),
                )
                return destination
            })
            .validationPolicy(validation)
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected response validation to reject the download")
        } catch is ResponseValidationError {
            // Rejected downloads do not resolve caller destinations.
        }

        #expect(resolver.values().isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        let source = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("Destination resolver errors propagate unchanged and clean the temporary file")
    func resolverErrorPropagatesUnchangedAndCleansTemporaryFile() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe7]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let request = try Request<DownloadedFile>(endpoint: makeDownloadEndpoint())
            .downloadDestination(.resolved(collisionPolicy: .failIfExists) { _, _ in
                throw DownloadResolverTestError.expected
            })
        let task = client.task(for: request)

        do {
            _ = try await task.value
            Issue.record("Expected the destination resolver to fail")
        } catch let error as DownloadResolverTestError {
            #expect(error == .expected)
        } catch {
            Issue.record("Unexpected resolver error: \(error)")
        }

        let source = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("Replacing an existing destination succeeds and preserves the downloaded contents")
    func replaceExistingReplacesCallerDestination() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xe8]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-replaced-\(UUID().uuidString)")
        try Data([0xfc]).write(to: destination)

        var response: Response<DownloadedFile>? = try await client.send(
            Request(endpoint: makeDownloadEndpoint())
                .downloadDestination(.file(destination, collisionPolicy: .replaceExisting)),
        )

        #expect(response?.attempts.count == 1)
        #expect(try Data(contentsOf: destination) == Data([0xe8]))
        response = nil
        #expect(try Data(contentsOf: destination) == Data([0xe8]))
        try FileManager.default.removeItem(at: destination)
    }

    @Test("DownloadedFile moves can replace an existing destination")
    func moveCanReplaceExistingDestination() async throws {
        let transport = ScriptedDownloadTransport([.init(body: Data([0xea]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        let destination = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-move-replaced-\(UUID().uuidString)")
        try Data([0xfe]).write(to: destination)
        var downloadedFile: DownloadedFile? = try await client.send(
            Request(endpoint: makeDownloadEndpoint()),
        )
        .value
        let source = try #require(await transport.createdFileURLs().first)

        try downloadedFile?.move(to: destination, collisionPolicy: .replaceExisting)

        #expect(downloadedFile?.url == destination)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try Data(contentsOf: destination) == Data([0xea]))
        downloadedFile = nil
        #expect(try Data(contentsOf: destination) == Data([0xea]))
        try FileManager.default.removeItem(at: destination)
    }

    @Test("A failed replacement preserves an existing caller file")
    func failedReplacementPreservesExistingCallerFile() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swift-networking-read-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.bin")
        let originalContents = Data([0xfd, 0xfd])
        try originalContents.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let transport = ScriptedDownloadTransport([.init(body: Data([0xe9]), statusCode: 200)])
        let client = try NetworkClient(transport: transport)
        var receivedExpectedError = false
        do {
            _ = try await client.send(
                Request(endpoint: makeDownloadEndpoint())
                    .downloadDestination(.file(destination, collisionPolicy: .replaceExisting)),
            )
            Issue.record("Expected replacement in a read-only directory to fail")
        } catch let error as DownloadFileError {
            if case let .finalizationFailed(_, errorDestination, _) = error {
                receivedExpectedError = true
                #expect(errorDestination == destination)
            } else {
                Issue.record("Unexpected download file error: \(error)")
            }
        } catch {
            Issue.record("Unexpected replacement error: \(error)")
        }

        #expect(receivedExpectedError)
        #expect(try Data(contentsOf: destination) == originalContents)
        let source = try #require(await transport.createdFileURLs().first)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("An abandoned ownership token automatically removes its library temporary file")
    func ownershipTokenCleansUpWhenReleased() throws {
        let foundationURL = try makeFoundationTemporaryFile(contents: Data([0xb1, 0xb2]))
        var ownership: DownloadedFileStorage? = try DownloadedFileStorage.adopt(foundationURL)
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
            let ownership = try DownloadedFileStorage.adopt(foundationURL)
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

private struct DownloadDestinationResolutionObservation: Sendable, Equatable {
    let statusCode: Int
    let contextValue: String?
    let destinationExisted: Bool
}

private final class DownloadDestinationResolverRecorder: Sendable {
    private let storage = Mutex<[DownloadDestinationResolutionObservation]>([])

    func record(_ observation: DownloadDestinationResolutionObservation) {
        storage.withLock { $0.append(observation) }
    }

    func values() -> [DownloadDestinationResolutionObservation] {
        storage.withLock { $0 }
    }
}

private enum DownloadDestinationContextKey: RequestContextKey {
    typealias Value = String
}

private enum DownloadResolverTestError: Error, Sendable, Equatable {
    case expected
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
