//
//  NetworkClient.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Synchronization

private struct RetryDecisionResolution {
    let customDecision: RetryPolicy.Decision
    let shouldRetry: Bool
    let wasForcedByCustomDecision: Bool
}

private func resolveRetryDecision(
    policy: RetryPolicy,
    context: RetryPolicy.Context,
    retryCount: UInt,
) -> RetryDecisionResolution? {
    guard retryCount < policy.maximumRetries else {
        return nil
    }

    let customDecision = policy.customDecision?(context) ?? .useBuiltInDecision
    let shouldRetry =
        switch customDecision {
        case .useBuiltInDecision:
            context.builtInDecision == .retry
        case .retry:
            true
        case .doNotRetry:
            false
        }
    return RetryDecisionResolution(
        customDecision: customDecision,
        shouldRetry: shouldRetry,
        wasForcedByCustomDecision: customDecision == .retry && context.builtInDecision != .retry,
    )
}

private func transportFailureRetryDiagnosticReason(
    error: any Error,
    classificationReason: RetryPolicy.Reason,
    wasForcedByCustomDecision: Bool,
) -> String {
    let decisionSource = wasForcedByCustomDecision
        ? "custom decision forced retry"
        : "built-in classification selected retry"
    return "transport error: \(String(describing: error)); \(decisionSource); "
        + "built-in reason: \(String(describing: classificationReason))"
}

private struct ResolvedAuthenticationConfiguration: Sendable {
    let provider: any AuthenticationProvider
    let maximumReplays: UInt
}

private func resolveAuthenticationConfiguration(
    requirement: AuthenticationRequirement,
    provider: (any AuthenticationProvider)?,
    requestID: RequestID,
) throws -> ResolvedAuthenticationConfiguration? {
    switch requirement {
    case .none:
        return nil
    case let .required(maximumReplays):
        guard let provider else {
            throw AuthenticationConfigurationError(requestID: requestID)
        }

        return ResolvedAuthenticationConfiguration(provider: provider, maximumReplays: maximumReplays)
    }
}

private func adaptRequestForAttempt(
    _ request: HTTPRequest,
    body: PreparedRequestBody,
    requestID: RequestID,
    context: RequestContext,
    adapters: [AnyRequestAdapter],
    authentication: ResolvedAuthenticationConfiguration?,
) async throws -> HTTPRequest {
    var adaptedRequest = request
    for adapter in adapters {
        adaptedRequest = try await adapter.adapt(
            RequestAdaptationContext(
                request: adaptedRequest,
                body: body,
                requestID: requestID,
                context: context,
            ),
        )
    }

    if let authentication {
        try Task.checkCancellation()
        adaptedRequest = try await authentication.provider.adapt(
            RequestAdaptationContext(
                request: adaptedRequest,
                body: body,
                requestID: requestID,
                context: context,
            ),
        )
        try Task.checkCancellation()
    }

    return adaptedRequest
}

private func authenticationReplayAttempt(
    authentication: ResolvedAuthenticationConfiguration?,
    replayCount: UInt,
    request: HTTPRequest,
    response: HTTPResponse,
    receivedBody: ReceivedResponseBody,
    requestContext: RequestContext,
    requestID: RequestID,
    attemptNumber: UInt,
    normalizedMetrics: NormalizedAttemptMetrics,
    rawTaskMetrics: URLSessionTaskMetrics?,
) async throws -> AttemptMetrics? {
    guard let authentication, replayCount < authentication.maximumReplays else {
        return nil
    }

    try Task.checkCancellation()
    let recovery = try await authentication.provider.recover(
        AuthenticationRecoveryContext(
            request: request,
            httpResponse: response,
            receivedBody: receivedBody,
            requestContext: requestContext,
            requestID: requestID,
            attemptNumber: attemptNumber,
        ),
    )
    try Task.checkCancellation()

    guard case .replay = recovery else {
        return nil
    }

    return AttemptMetrics(
        requestID: requestID,
        attemptNumber: attemptNumber,
        normalizedMetrics: normalizedMetrics,
        outcome: .authenticationReplayScheduled,
        diagnosticReason: "authentication provider requested immediate replay",
        rawTaskMetrics: rawTaskMetrics,
    )
}

package protocol NetworkTransport: Sendable {
    func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse)
    /// Executes one attempt, publishes its start, and reports byte-transfer updates.
    func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult
    /// Executes a download attempt that returns an owned file rather than response bytes.
    func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult
}

package enum TransportExecutionError: Error, Sendable {
    case downloadRequiresFileBackedResult
    case responseBodyRepresentationMismatch
}

private enum SuccessfulTransportBody: Sendable {
    case data(Data)
    case file(DownloadedFileStorage)

    var receivedResponseBody: ReceivedResponseBody {
        switch self {
        case let .data(data):
            .data(data)
        case let .file(file):
            .file(file.url)
        }
    }

    func retainedBody(using policy: BodyRetentionPolicy) throws -> RetainedBody? {
        switch self {
        case let .data(data):
            policy.retain(data)
        case let .file(file):
            try policy.retain(fileAt: file.url)
        }
    }

    func retainedBodyForAcceptedResponse(using policy: BodyRetentionPolicy) -> RetainedBody? {
        switch self {
        case let .data(data):
            policy.retain(data)
        case .file:
            nil
        }
    }

    func discardFile() {
        guard case let .file(file) = self else {
            return
        }

        file.discard()
    }
}

private func makeSuccessfulResponseValue<Output: Sendable>(
    responseHandling: EndpointResponseHandling<Output>,
    body: SuccessfulTransportBody,
    response: HTTPResponse,
    clientJSONDecoderConfiguration: JSONDecoderConfiguration,
    endpointJSONDecoderConfiguration: JSONDecoderConfiguration,
) throws -> Output {
    switch (responseHandling, body) {
    case let (.decode(decoding), .data(data)):
        return try decoding.decode(
            data,
            response: response,
            clientJSONDecoderConfiguration: clientJSONDecoderConfiguration,
            endpointJSONDecoderConfiguration: endpointJSONDecoderConfiguration,
        )
    case let (.download(makeValue), .file(file)):
        return makeValue(file)
    default:
        body.discardFile()
        throw TransportExecutionError.responseBodyRepresentationMismatch
    }
}

private func finalizeSuccessfulDownload(
    body: SuccessfulTransportBody,
    destination: DownloadDestination,
    response: HTTPResponse,
    context: RequestContext,
) throws {
    guard case let .file(file) = body else {
        return
    }

    do {
        let target: URL
        let collisionPolicy: DownloadCollisionPolicy
        switch destination {
        case .temporary:
            return
        case let .file(url, policy):
            target = url
            collisionPolicy = policy
        case let .resolved(policy, resolver):
            target = try resolver(response, context)
            collisionPolicy = policy
        }

        try file.finalize(to: target, collisionPolicy: collisionPolicy)
    } catch {
        file.discard()
        throw error
    }
}

private enum TransportAttemptResult: Sendable {
    case success(body: SuccessfulTransportBody, response: HTTPResponse, rawTaskMetrics: URLSessionTaskMetrics?)
    case failure(error: any Error, rawTaskMetrics: URLSessionTaskMetrics?, didStartTask: Bool)
    case redirectLimitExceeded(
        maximumRedirects: UInt,
        lastResponse: HTTPResponse?,
        rawTaskMetrics: URLSessionTaskMetrics?,
    )
}

extension NetworkTransportResult {
    fileprivate var attemptResult: TransportAttemptResult {
        switch self {
        case let .success(data, response, rawTaskMetrics):
            .success(
                body: .data(data),
                response: response,
                rawTaskMetrics: rawTaskMetrics,
            )
        case let .failure(error, rawTaskMetrics, didStartTask):
            .failure(error: error, rawTaskMetrics: rawTaskMetrics, didStartTask: didStartTask)
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
            .redirectLimitExceeded(
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                rawTaskMetrics: rawTaskMetrics,
            )
        }
    }
}

extension NetworkTransportDownloadResult {
    fileprivate var attemptResult: TransportAttemptResult {
        switch self {
        case let .success(file, response, rawTaskMetrics):
            .success(body: .file(file), response: response, rawTaskMetrics: rawTaskMetrics)
        case let .failure(error, rawTaskMetrics, didStartTask):
            .failure(error: error, rawTaskMetrics: rawTaskMetrics, didStartTask: didStartTask)
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
            .redirectLimitExceeded(
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                rawTaskMetrics: rawTaskMetrics,
            )
        }
    }
}

private func executeTransportAttempt(
    using transport: any NetworkTransport,
    request: TransportRequest,
    progress: NetworkProgressReporter,
) async -> TransportAttemptResult {
    if request.operation == .download {
        let result = await transport.executeDownloadWithMetrics(request, progress: progress)
        return result.attemptResult
    }

    let result = await transport.executeWithMetrics(request, progress: progress)
    return result.attemptResult
}

extension NetworkTransport {
    /// Adapts a transport that exposes only the tuple-returning operation.
    ///
    /// The execute-only contract treats entry into `execute` as the start of an attempt. A
    /// conformer that can fail before starting transport work must implement this progress-aware
    /// method and report an attempt only after its own start decision succeeds.
    package func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        guard request.operation != .download else {
            return .failure(
                error: TransportExecutionError.downloadRequiresFileBackedResult,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        progress.startAttempt(
            attemptNumber: request.attemptNumber,
            expectedBytesToSend: expectedRequestBodyByteCount(request.execution),
        )
        do {
            let (data, response) = try await execute(request)
            return .success(data: data, response: response, rawTaskMetrics: nil)
        } catch {
            return .failure(error: error, rawTaskMetrics: nil, didStartTask: true)
        }
    }

    /// Executes through the progress-aware transport seam without retaining progress updates.
    package func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        await executeWithMetrics(request, progress: NetworkProgressCoordinator().reporter)
    }

    /// Rejects downloads for transports that only provide in-memory response bytes.
    package func executeDownloadWithMetrics(
        _: TransportRequest,
        progress _: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        .failure(
            error: TransportExecutionError.downloadRequiresFileBackedResult,
            rawTaskMetrics: nil,
            didStartTask: false,
        )
    }
}

/// Creates a foreground session configuration using the client's policy defaults.
///
/// URL cache and cookie storage use the client values, while credential storage remains disabled.
/// Unspecified session options retain Foundation's defaults.
package func makeForegroundURLSessionConfiguration(
    configuration clientConfiguration: NetworkClient.Configuration = .init(),
) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = clientConfiguration.urlCache
    configuration.httpCookieStorage = clientConfiguration.httpCookieStorage
    configuration.urlCredentialStorage = nil

    if let requestTimeout = clientConfiguration.requestTimeout {
        configuration.timeoutIntervalForRequest = durationTimeInterval(requestTimeout)
    }
    if let resourceTimeout = clientConfiguration.resourceTimeout {
        configuration.timeoutIntervalForResource = durationTimeInterval(resourceTimeout)
    }
    if let waitsForConnectivity = clientConfiguration.waitsForConnectivity {
        configuration.waitsForConnectivity = waitsForConnectivity
    }
    if let allowsExpensiveNetworkAccess = clientConfiguration.allowsExpensiveNetworkAccess {
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
    }
    if let allowsConstrainedNetworkAccess = clientConfiguration.allowsConstrainedNetworkAccess {
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }
    if let allowsCellularAccess = clientConfiguration.allowsCellularAccess {
        configuration.allowsCellularAccess = allowsCellularAccess
    }
    if let cachePolicy = clientConfiguration.cachePolicy {
        configuration.requestCachePolicy = cachePolicy
    }

    return configuration
}

/// Converts an HTTP request into the Foundation request sent by URLSession.
///
/// - Parameters:
///   - request: The finalized HTTP request produced by client routing and composition.
///   - assumesHTTP3Capable: The optional client preference to apply to the first attempt.
/// - Returns: The Foundation request, or nil when it cannot represent the HTTP request.
package func makeURLRequest(
    _ request: HTTPRequest,
    assumesHTTP3Capable: Bool?,
) -> URLRequest? {
    guard var urlRequest = URLRequest(httpRequest: request) else {
        return nil
    }

    if let assumesHTTP3Capable {
        urlRequest.assumesHTTP3Capable = assumesHTTP3Capable
    }

    return urlRequest
}

/// Converts transport metadata and a data-task or upload execution into a Foundation request.
///
/// Incompatible operation and body combinations return nil because URLSession cannot execute them.
package func makeURLRequest(
    _ request: TransportRequest,
    assumesHTTP3Capable: Bool?,
) -> URLRequest? {
    guard let execution = request.execution else {
        return nil
    }
    guard var urlRequest = makeURLRequest(
        request.httpRequest,
        assumesHTTP3Capable: assumesHTTP3Capable,
    ) else {
        return nil
    }

    switch execution {
    case let .data(body):
        if let body {
            urlRequest.httpBody = body
        }
    case let .download(body):
        if let body {
            urlRequest.httpBody = body
        }
    case .uploadFromData,
         .uploadFromFile:
        urlRequest.httpBody = nil
    }

    return urlRequest
}

/// Confirms that a caller-owned URL refers to a readable regular local file without loading it.
private func validateFileBody(_ url: URL, requestID: RequestID) throws {
    guard url.isFileURL,
          let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
          resourceValues.isRegularFile == true
    else {
        throw RequestConstructionError(requestID: requestID, reason: .unreadableFileBody)
    }

    do {
        let file = try FileHandle(forReadingFrom: url)
        try file.close()
    } catch {
        throw RequestConstructionError(requestID: requestID, reason: .unreadableFileBody)
    }
}

/// Converts a positive Swift duration into Foundation's seconds-based timeout value.
private func durationTimeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

package struct URLSessionTransport: NetworkTransport {
    private let session: URLSession
    private let delegateRouter: URLSessionDelegateRouter
    private let assumesHTTP3Capable: Bool?
    private let beforeTaskStart: (@Sendable () async -> Void)?

    /// Creates the one foreground session shared by every attempt executed by this transport.
    ///
    /// - Parameters:
    ///   - configuration: The client policies used to configure a production foreground session.
    ///   - sessionConfiguration: An optional package-only session configuration for deterministic tests.
    ///   - beforeTaskStart: An optional package-only hook for holding task start in deterministic tests.
    package init(
        configuration: NetworkClient.Configuration,
        sessionConfiguration: URLSessionConfiguration? = nil,
        beforeTaskStart: (@Sendable () async -> Void)? = nil,
    ) {
        let router = URLSessionDelegateRouter()
        delegateRouter = router
        session = URLSession(
            configuration: sessionConfiguration
                ?? makeForegroundURLSessionConfiguration(configuration: configuration),
            delegate: router,
            delegateQueue: nil,
        )
        assumesHTTP3Capable = configuration.assumesHTTP3Capable
        self.beforeTaskStart = beforeTaskStart
    }

    package func execute(_ request: TransportRequest) async throws -> (Data, HTTPResponse) {
        guard request.operation != .download else {
            throw TransportExecutionError.downloadRequiresFileBackedResult
        }

        switch await executeWithMetrics(request) {
        case let .success(data, response, _):
            return (data, response)
        case let .failure(error, _, _):
            throw error
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
            let attempt = AttemptMetrics(
                requestID: request.requestID,
                attemptNumber: request.attemptNumber,
                normalizedMetrics: NormalizedAttemptMetrics(taskMetrics: rawTaskMetrics),
                outcome: .redirectLimitExceeded,
                diagnosticReason: nil,
                rawTaskMetrics: rawTaskMetrics,
            )
            throw RedirectError.tooManyRedirects(
                requestID: request.requestID,
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                attempts: [attempt],
            )
        }
    }

    package func executeWithMetrics(_ request: TransportRequest) async -> NetworkTransportResult {
        await executeWithMetrics(request, progress: NetworkProgressCoordinator().reporter)
    }

    package func executeWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportResult {
        guard request.operation != .download else {
            return .failure(
                error: TransportExecutionError.downloadRequiresFileBackedResult,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        switch await executeAttempt(request, progress: progress) {
        case let .success(body: .data(data), response, rawTaskMetrics):
            return .success(data: data, response: response, rawTaskMetrics: rawTaskMetrics)
        case .success(body: .file, response: _, rawTaskMetrics: _):
            return .failure(
                error: TransportExecutionError.responseBodyRepresentationMismatch,
                rawTaskMetrics: nil,
                didStartTask: true,
            )
        case let .failure(error, rawTaskMetrics, didStartTask):
            return .failure(error: error, rawTaskMetrics: rawTaskMetrics, didStartTask: didStartTask)
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
            return .redirectLimitExceeded(
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                rawTaskMetrics: rawTaskMetrics,
            )
        }
    }

    package func executeDownloadWithMetrics(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> NetworkTransportDownloadResult {
        guard request.operation == .download else {
            return .failure(
                error: TransportExecutionError.responseBodyRepresentationMismatch,
                rawTaskMetrics: nil,
                didStartTask: false,
            )
        }

        switch await executeAttempt(request, progress: progress) {
        case let .success(body: .file(file), response, rawTaskMetrics):
            return .success(file: file, response: response, rawTaskMetrics: rawTaskMetrics)
        case .success(body: .data, response: _, rawTaskMetrics: _):
            return .failure(
                error: TransportExecutionError.responseBodyRepresentationMismatch,
                rawTaskMetrics: nil,
                didStartTask: true,
            )
        case let .failure(error, rawTaskMetrics, didStartTask):
            return .failure(error: error, rawTaskMetrics: rawTaskMetrics, didStartTask: didStartTask)
        case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
            return .redirectLimitExceeded(
                maximumRedirects: maximumRedirects,
                lastResponse: lastResponse,
                rawTaskMetrics: rawTaskMetrics,
            )
        }
    }

    private func executeAttempt(
        _ request: TransportRequest,
        progress: NetworkProgressReporter,
    ) async -> TransportAttemptResult {
        guard let execution = request.execution,
              let urlRequest = makeURLRequest(
                  request,
                  assumesHTTP3Capable: assumesHTTP3Capable,
              )
        else {
            return .failure(error: URLError(.badURL), rawTaskMetrics: nil, didStartTask: false)
        }

        let delegate = URLSessionTaskMetricsDelegate(
            transportRequest: request,
            initialRequest: urlRequest,
            progressReporter: progress,
        )
        let task =
            switch execution {
            case .data:
                session.dataTask(with: urlRequest)
            case let .uploadFromData(body):
                session.uploadTask(with: urlRequest, from: body)
            case let .uploadFromFile(fileURL):
                session.uploadTask(with: urlRequest, fromFile: fileURL)
            case .download:
                session.downloadTask(with: urlRequest)
            }

        delegateRouter.register(delegate, for: task.taskIdentifier)
        let startControl = URLSessionTaskStartControl()
        let taskCompletion = await withTaskCancellationHandler {
            await beforeTaskStart?()
            return await withCheckedContinuation { continuation in
                guard startControl.start(
                    task,
                    delegate: delegate,
                    attemptNumber: request.attemptNumber,
                    expectedBytesToSend: expectedRequestBodyByteCount(execution),
                    progress: progress,
                    continuation: continuation,
                ) else {
                    continuation.resume(returning: .notStarted)
                    return
                }
            }
        } onCancel: {
            startControl.cancel(task)
        }

        guard startControl.didStartTask,
              case let .completed(taskResult) = taskCompletion
        else {
            delegateRouter.unregister(delegate, for: task.taskIdentifier)
            return .failure(error: CancellationError(), rawTaskMetrics: nil, didStartTask: false)
        }

        let rawTaskMetrics = await delegate.taskMetricsAfterCompletion()
        if let limit = delegate.redirectLimitExceeded() {
            return .redirectLimitExceeded(
                maximumRedirects: limit.maximumRedirects,
                lastResponse: limit.lastResponse,
                rawTaskMetrics: rawTaskMetrics,
            )
        }

        let payload: URLSessionTaskPayload
        switch taskResult {
        case let .success(completedPayload):
            payload = completedPayload
        case let .failure(error):
            return .failure(error: error, rawTaskMetrics: rawTaskMetrics, didStartTask: true)
        }

        guard let response = (payload.response as? HTTPURLResponse)?.httpResponse else {
            return .failure(error: URLError(.badServerResponse), rawTaskMetrics: rawTaskMetrics, didStartTask: true)
        }

        switch payload.body {
        case let .data(data):
            return .success(body: .data(data), response: response, rawTaskMetrics: rawTaskMetrics)
        case let .file(file):
            return .success(body: .file(file), response: response, rawTaskMetrics: rawTaskMetrics)
        }
    }
}

/// Serializes attempt start with cancellation for one suspended URLSession task.
private final class URLSessionTaskStartControl: Sendable {
    private enum State: Sendable, Equatable {
        case pending
        case cancelled
        case starting(cancelAfterResume: Bool)
        case started
    }

    private let state = Mutex(State.pending)

    var didStartTask: Bool {
        state.withLock { currentState in
            switch currentState {
            case .starting,
                 .started:
                true
            case .pending,
                 .cancelled:
                false
            }
        }
    }

    func start(
        _ task: URLSessionTask,
        delegate: URLSessionTaskMetricsDelegate,
        attemptNumber: UInt,
        expectedBytesToSend: Int64?,
        progress: NetworkProgressReporter,
        continuation: CheckedContinuation<URLSessionTaskExecutionResult, Never>,
    ) -> Bool {
        let didCommitStart = state.withLock { currentState in
            guard currentState == .pending else {
                return false
            }
            guard Task.isCancelled == false else {
                currentState = .cancelled
                return false
            }

            // Install the waiter before committing start so an early completion is retained.
            delegate.waitForTaskCompletion(continuation)
            currentState = .starting(cancelAfterResume: false)
            return true
        }

        guard didCommitStart else {
            task.cancel()
            return false
        }

        progress.startAttempt(
            attemptNumber: attemptNumber,
            expectedBytesToSend: expectedBytesToSend,
        )
        task.resume()

        let shouldCancelAfterResume = state.withLock { currentState in
            guard case let .starting(cancelAfterResume) = currentState else {
                return false
            }

            currentState = .started
            return cancelAfterResume
        }
        if shouldCancelAfterResume {
            task.cancel()
        }

        return true
    }

    func cancel(_ task: URLSessionTask) {
        let shouldCancelTask = state.withLock { currentState in
            switch currentState {
            case .pending:
                currentState = .cancelled
                return true
            case .cancelled:
                return false
            case .starting:
                currentState = .starting(cancelAfterResume: true)
                return false
            case .started:
                return true
            }
        }
        if shouldCancelTask {
            task.cancel()
        }
    }
}

private func expectedRequestBodyByteCount(_ execution: TransportExecution?) -> Int64? {
    guard let execution else {
        return nil
    }

    switch execution {
    case let .data(body):
        guard let body else {
            return 0
        }

        return Int64(exactly: body.count)
    case let .download(body):
        guard let body else {
            return 0
        }

        return Int64(exactly: body.count)
    case let .uploadFromData(body):
        return Int64(exactly: body.count)
    case let .uploadFromFile(fileURL):
        guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }

        return Int64(exactly: fileSize)
    }
}

struct RedirectLimitExceeded: Sendable {
    let maximumRedirects: UInt
    let lastResponse: HTTPResponse?
}

private enum URLSessionTaskBody: Sendable {
    case data(Data)
    case file(DownloadedFileStorage)
}

private struct URLSessionTaskPayload: Sendable {
    let body: URLSessionTaskBody
    let response: URLResponse?
}

private func makeURLSessionTaskResult(
    error: (any Error)?,
    isDownloadTask: Bool,
    adoptionError: (any Error)?,
    downloadedFile: DownloadedFileStorage?,
    receivedData: Data,
    response: URLResponse?,
) -> Result<URLSessionTaskPayload, any Error> {
    if let error {
        return .failure(error)
    }

    guard isDownloadTask else {
        return .success(
            URLSessionTaskPayload(
                body: .data(receivedData),
                response: response,
            ),
        )
    }

    if let adoptionError {
        return .failure(adoptionError)
    }

    guard let downloadedFile else {
        return .failure(URLError(.cannotCreateFile))
    }

    return .success(
        URLSessionTaskPayload(
            body: .file(downloadedFile),
            response: response,
        ),
    )
}

/// Separates cancellation before task start from the result of a started URLSession task.
private enum URLSessionTaskExecutionResult: Sendable {
    /// The cancellation/start gate prevented the suspended task from starting.
    case notStarted

    /// The started task delivered its completion result through the session delegate.
    case completed(Result<URLSessionTaskPayload, any Error>)
}

/// Tracks task completion separately from completion of metrics collection.
///
/// Foundation may deliver these lifecycle callbacks in either order. A result becomes available
/// only after both events have arrived, so task completion cannot discard a later metrics value.
struct TaskMetricsCollectionState<Metrics: Sendable>: Sendable {
    private var didCompleteTask = false
    private var didFinishCollecting = false
    private var metrics: Metrics?

    mutating func taskDidComplete() {
        didCompleteTask = true
    }

    mutating func finishCollecting(_ metrics: Metrics?) {
        guard didFinishCollecting == false else {
            return
        }

        self.metrics = metrics
        didFinishCollecting = true
    }

    var result: Metrics?? {
        guard didCompleteTask, didFinishCollecting else {
            return nil
        }

        return .some(metrics)
    }
}

/// Coordinates task completion with the delegate's metrics collection callback.
///
/// A mutex protects the lifecycle state and waiting continuations, including when callbacks arrive
/// in either order or collection explicitly finishes without metrics.
final class URLSessionTaskMetricsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State: Sendable {
        var metricsCollection = TaskMetricsCollectionState<URLSessionTaskMetrics>()
        var waiters: [CheckedContinuation<URLSessionTaskMetrics?, Never>] = []
        var taskResult: Result<URLSessionTaskPayload, any Error>?
        var taskResultWaiters: [CheckedContinuation<URLSessionTaskExecutionResult, Never>] = []
        var receivedData = Data()
        var downloadedFile: DownloadedFileStorage?
        var downloadFileAdoptionError: (any Error)?
        var response: URLResponse?
        var followedRedirectCount: UInt = 0
        var redirectOrdinal: UInt = 0
        var redirectLimitExceeded: RedirectLimitExceeded?

        mutating func takeReadyWaiters() -> (
            URLSessionTaskMetrics??,
            [CheckedContinuation<URLSessionTaskMetrics?, Never>],
        ) {
            let result = metricsCollection.result
            guard result != nil else {
                return (nil, [])
            }

            let readyWaiters = waiters
            waiters.removeAll()
            return (result, readyWaiters)
        }
    }

    private let state = Mutex(State())
    private let redirectPolicy: RedirectPolicy
    private let requestID: RequestID
    private let requestContext: RequestContext
    private let attemptNumber: UInt
    private let initialRequest: URLRequest
    private let progressReporter: NetworkProgressReporter?
    private let isDownloadTask: Bool

    init(
        transportRequest: TransportRequest,
        initialRequest: URLRequest,
        progressReporter: NetworkProgressReporter? = nil,
    ) {
        redirectPolicy = transportRequest.redirectPolicy
        requestID = transportRequest.requestID
        requestContext = transportRequest.requestContext
        attemptNumber = transportRequest.attemptNumber
        self.initialRequest = initialRequest
        self.progressReporter = progressReporter
        isDownloadTask = transportRequest.operation == .download
    }

    func recordResponse(_ response: URLResponse) {
        let receivedByteCount = state.withLock { storage -> Int64 in
            storage.response = response
            return Int64(clamping: storage.receivedData.count)
        }
        let expectedByteCount = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        progressReporter?.updateDownload(
            bytesReceived: receivedByteCount,
            expectedBytesToReceive: expectedByteCount,
        )
    }

    func recordDownloadedFile(at foundationURL: URL, response: URLResponse?) {
        do {
            let file = try DownloadedFileStorage.adopt(foundationURL)
            let didStoreFile = state.withLock { storage -> Bool in
                guard storage.taskResult == nil else {
                    return false
                }

                storage.response = response ?? storage.response
                storage.downloadedFile = file
                return true
            }
            if didStoreFile == false {
                file.discard()
            }
        } catch {
            state.withLock { storage in
                guard storage.taskResult == nil else {
                    return
                }

                storage.downloadFileAdoptionError = error
            }
        }
    }

    func recordReceivedData(_ data: Data) {
        let (receivedByteCount, expectedByteCount) = state.withLock { storage -> (Int64, Int64?) in
            storage.receivedData.append(data)
            let expectedByteCount = storage.response?.expectedContentLength
            return (
                Int64(clamping: storage.receivedData.count),
                expectedByteCount.flatMap { $0 >= 0 ? $0 : nil },
            )
        }
        progressReporter?.updateDownload(
            bytesReceived: receivedByteCount,
            expectedBytesToReceive: expectedByteCount,
        )
    }

    func recordUploadProgress(bytesSent: Int64, expectedBytesToSend: Int64) {
        progressReporter?.updateUpload(
            bytesSent: bytesSent,
            expectedBytesToSend: expectedBytesToSend,
        )
    }

    func recordDownloadProgress(bytesWritten: Int64, expectedBytesToWrite: Int64) {
        let expectedBytesToReceive: Int64? = expectedBytesToWrite >= 0 ? expectedBytesToWrite : nil
        progressReporter?.updateDownload(
            bytesReceived: bytesWritten,
            expectedBytesToReceive: expectedBytesToReceive,
        )
    }

    fileprivate func waitForTaskCompletion(
        _ continuation: CheckedContinuation<URLSessionTaskExecutionResult, Never>,
    ) {
        let taskResult = state.withLock { storage -> URLSessionTaskExecutionResult? in
            if let taskResult = storage.taskResult {
                return .completed(taskResult)
            }
            storage.taskResultWaiters.append(continuation)
            return nil
        }
        if let taskResult {
            continuation.resume(returning: taskResult)
        }
    }

    func isReadyForRemoval() -> Bool {
        state.withLock { $0.metricsCollection.result != nil }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics,
    ) {
        state.withLock { $0.metricsCollection.finishCollecting(metrics) }
        resumeReadyWaiters()
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: (URLRequest?) -> Void,
    ) {
        let redirectOrdinal = state.withLock { storage in
            storage.redirectOrdinal += 1
            return storage.redirectOrdinal
        }

        guard let httpResponse = response.httpResponse else {
            completionHandler(nil)
            return
        }

        let context = RedirectPolicy.Context(
            currentRequest: task.currentRequest ?? initialRequest,
            proposedRequest: newRequest,
            httpResponse: httpResponse,
            requestID: requestID,
            requestContext: requestContext,
            attemptNumber: attemptNumber,
            redirectOrdinal: redirectOrdinal,
        )
        guard redirectPolicy.decision(for: context) == .follow else {
            completionHandler(nil)
            return
        }

        let exceededLimit = state.withLock { storage in
            guard storage.followedRedirectCount >= redirectPolicy.maximumRedirects else {
                storage.followedRedirectCount += 1
                return false
            }

            storage.redirectLimitExceeded = RedirectLimitExceeded(
                maximumRedirects: redirectPolicy.maximumRedirects,
                lastResponse: httpResponse,
            )
            return true
        }
        completionHandler(exceededLimit ? nil : newRequest)
    }

    func redirectLimitExceeded() -> RedirectLimitExceeded? {
        state.withLock(\.redirectLimitExceeded)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?,
    ) {
        let (taskResult, taskWaiters) = state.withLock { storage -> (
            Result<URLSessionTaskPayload, any Error>,
            [CheckedContinuation<URLSessionTaskExecutionResult, Never>],
        ) in
            let result = makeURLSessionTaskResult(
                error: error,
                isDownloadTask: isDownloadTask,
                adoptionError: storage.downloadFileAdoptionError,
                downloadedFile: storage.downloadedFile,
                receivedData: storage.receivedData,
                response: storage.response,
            )
            storage.taskResult = result
            let waiters = storage.taskResultWaiters
            storage.taskResultWaiters.removeAll()
            storage.metricsCollection.taskDidComplete()
            return (result, waiters)
        }
        for waiter in taskWaiters {
            waiter.resume(returning: .completed(taskResult))
        }
        resumeReadyWaiters()
    }

    func taskMetricsAfterCompletion() async -> URLSessionTaskMetrics? {
        await withCheckedContinuation { continuation in
            let readyMetrics = state.withLock { storage -> URLSessionTaskMetrics?? in
                if let readyMetrics = storage.metricsCollection.result {
                    return .some(readyMetrics)
                }

                storage.waiters.append(continuation)
                return nil
            }

            if let readyMetrics {
                continuation.resume(returning: readyMetrics)
            }
        }
    }

    private func resumeReadyWaiters() {
        let (readyMetrics, waiters) = state.withLock { $0.takeReadyWaiters() }
        guard let readyMetrics else {
            return
        }

        for waiter in waiters {
            waiter.resume(returning: readyMetrics)
        }
    }
}

/// Routes callbacks from the client's single foreground URLSession to the state for each task.
final class URLSessionDelegateRouter: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, Sendable {
    private let delegates = Mutex<[Int: URLSessionTaskMetricsDelegate]>([:])

    func register(_ delegate: URLSessionTaskMetricsDelegate, for taskIdentifier: Int) {
        delegates.withLock { $0[taskIdentifier] = delegate }
    }

    func unregister(_ delegate: URLSessionTaskMetricsDelegate, for taskIdentifier: Int) {
        delegates.withLock { storage in
            guard storage[taskIdentifier] === delegate else {
                return
            }

            storage.removeValue(forKey: taskIdentifier)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: (URLSession.ResponseDisposition) -> Void,
    ) {
        delegate(for: dataTask.taskIdentifier)?.recordResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        delegate(for: dataTask.taskIdentifier)?.recordReceivedData(data)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL,
    ) {
        delegate(for: downloadTask.taskIdentifier)?.recordDownloadedFile(
            at: location,
            response: downloadTask.response,
        )
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
    ) {
        delegate(for: downloadTask.taskIdentifier)?.recordDownloadProgress(
            bytesWritten: totalBytesWritten,
            expectedBytesToWrite: totalBytesExpectedToWrite,
        )
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64,
    ) {
        delegate(for: task.taskIdentifier)?.recordUploadProgress(
            bytesSent: totalBytesSent,
            expectedBytesToSend: totalBytesExpectedToSend,
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        guard let delegate = delegate(for: task.taskIdentifier) else {
            completionHandler(newRequest)
            return
        }

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest,
            completionHandler: completionHandler,
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics,
    ) {
        guard let delegate = delegate(for: task.taskIdentifier) else {
            return
        }

        delegate.urlSession(session, task: task, didFinishCollecting: metrics)
        removeIfReady(delegate, taskIdentifier: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?,
    ) {
        guard let delegate = delegate(for: task.taskIdentifier) else {
            return
        }

        delegate.urlSession(session, task: task, didCompleteWithError: error)
        removeIfReady(delegate, taskIdentifier: task.taskIdentifier)
    }

    private func delegate(for taskIdentifier: Int) -> URLSessionTaskMetricsDelegate? {
        delegates.withLock { $0[taskIdentifier] }
    }

    private func removeIfReady(_ delegate: URLSessionTaskMetricsDelegate, taskIdentifier: Int) {
        guard delegate.isReadyForRemoval() else {
            return
        }

        delegates.withLock { storage in
            guard storage[taskIdentifier] === delegate else {
                return
            }

            storage.removeValue(forKey: taskIdentifier)
        }
    }
}

/// Selects whether an immutable configuration field keeps its current value or receives a replacement.
private enum ConfigurationFieldUpdate<Value> {
    case unchanged
    case set(Value)

    func applying(to currentValue: Value) -> Value {
        switch self {
        case .unchanged:
            currentValue
        case let .set(value):
            value
        }
    }
}

/// An immutable execution environment that owns its foreground URL session.
public final class NetworkClient: Sendable {
    /// Describes every invalid base URL or timeout setting discovered during client initialization.
    public struct ConfigurationError: Error, Sendable, Equatable {
        /// Identifies a base URL rule or timeout policy that failed validation.
        public enum Failure: Sendable, Equatable {
            /// The base URL does not use the HTTP or HTTPS scheme.
            case baseURLScheme

            /// The base URL contains a query component.
            case baseURLQuery

            /// The base URL contains a fragment component.
            case baseURLFragment

            /// The client request timeout is zero or negative.
            case requestTimeout

            /// The client resource timeout is zero or negative.
            case resourceTimeout
        }

        /// The failures in stable base URL, request timeout, resource timeout order.
        public let failures: [Failure]

        package init(failures: [Failure]) {
            self.failures = failures
        }
    }

    /// The immutable configuration used when creating a client.
    public struct Configuration: Sendable {
        /// The optional HTTP or HTTPS base URL used to compose relative routes.
        public let baseURL: URL?

        /// Client-wide default HTTP fields applied before endpoint and request fields.
        public let defaultHeaders: HTTPFields

        /// Static query items applied to relative routes before endpoint and request query items.
        public let defaultQueryItems: [URLQueryItem]

        /// Client-wide defaults for Codable query serialization.
        public let urlQueryEncoderConfiguration: URLQueryEncoder.Configuration

        /// Client-wide configuration applied to each fresh JSON request encoder.
        public let jsonEncoderConfiguration: @Sendable (JSONEncoder) -> Void

        /// Client-wide configuration applied to each fresh JSON response decoder.
        public let jsonDecoderConfiguration: @Sendable (JSONDecoder) -> Void

        /// The URL cache used by the foreground session. A nil value disables URL caching.
        public let urlCache: URLCache?

        /// The cookie storage used by the foreground session. A nil value disables cookie storage.
        public let httpCookieStorage: HTTPCookieStorage?

        /// The client-wide request timeout, or nil to preserve Foundation's default.
        ///
        /// An explicit value must be greater than zero when a client is created.
        public let requestTimeout: Duration?

        /// The client-wide resource timeout, or nil to preserve Foundation's default.
        ///
        /// An explicit value must be greater than zero when a client is created.
        public let resourceTimeout: Duration?

        /// Whether the foreground session waits for connectivity, or nil to preserve its default.
        public let waitsForConnectivity: Bool?

        /// Whether the foreground session may use expensive networks, or nil to preserve its default.
        public let allowsExpensiveNetworkAccess: Bool?

        /// Whether the foreground session may use constrained networks, or nil to preserve its default.
        public let allowsConstrainedNetworkAccess: Bool?

        /// Whether the foreground session may use cellular networks, or nil to preserve its default.
        public let allowsCellularAccess: Bool?

        /// The cache policy used by the foreground session, or nil to preserve Foundation's default.
        public let cachePolicy: URLRequest.CachePolicy?

        /// The default policy used to validate each final transport response.
        public let responseValidationPolicy: ResponseValidationPolicy

        /// The default bounded retry policy, with retries disabled unless explicitly configured.
        public let retryPolicy: RetryPolicy

        /// The default policy used when deciding whether URLSession follows an HTTP redirect.
        public let redirectPolicy: RedirectPolicy

        /// The provider used by endpoints that require authentication.
        public let authenticationProvider: (any AuthenticationProvider)?

        /// The default policy for retaining bodies of accepted responses.
        public let successfulResponseBodyRetentionPolicy: BodyRetentionPolicy

        /// The default policy for retaining bodies of rejected responses.
        public let validationErrorBodyRetentionPolicy: BodyRetentionPolicy

        /// The HTTP/3 first-attempt preference for outgoing requests, or nil to preserve Foundation's value.
        public let assumesHTTP3Capable: Bool?

        package let requestIDGenerator: any RequestIDGenerator
        package let requestAdapters: [AnyRequestAdapter]

        /// Creates client configuration with an optional base URL.
        ///
        /// - Parameter baseURL: The HTTP or HTTPS base URL used for relative routes. It must not
        ///   contain a query or fragment.
        public init(baseURL: URL? = nil) {
            self.baseURL = baseURL
            defaultHeaders = HTTPFields()
            defaultQueryItems = []
            urlQueryEncoderConfiguration = .init()
            jsonEncoderConfiguration = { _ in }
            jsonDecoderConfiguration = { _ in }
            urlCache = nil
            httpCookieStorage = nil
            requestTimeout = nil
            resourceTimeout = nil
            waitsForConnectivity = nil
            allowsExpensiveNetworkAccess = nil
            allowsConstrainedNetworkAccess = nil
            allowsCellularAccess = nil
            cachePolicy = nil
            responseValidationPolicy = .successfulStatusCodes
            retryPolicy = RetryPolicy()
            redirectPolicy = .follow
            authenticationProvider = nil
            successfulResponseBodyRetentionPolicy = .none
            validationErrorBodyRetentionPolicy = .unlimited
            assumesHTTP3Capable = nil
            requestIDGenerator = UUIDRequestIDGenerator()
            requestAdapters = []
        }

        private init(
            baseURL: URL?,
            defaultHeaders: HTTPFields,
            defaultQueryItems: [URLQueryItem],
            urlQueryEncoderConfiguration: URLQueryEncoder.Configuration,
            jsonEncoderConfiguration: @escaping JSONEncoderConfiguration,
            jsonDecoderConfiguration: @escaping JSONDecoderConfiguration,
            urlCache: URLCache?,
            httpCookieStorage: HTTPCookieStorage?,
            requestTimeout: Duration?,
            resourceTimeout: Duration?,
            waitsForConnectivity: Bool?,
            allowsExpensiveNetworkAccess: Bool?,
            allowsConstrainedNetworkAccess: Bool?,
            allowsCellularAccess: Bool?,
            cachePolicy: URLRequest.CachePolicy?,
            responseValidationPolicy: ResponseValidationPolicy,
            retryPolicy: RetryPolicy,
            redirectPolicy: RedirectPolicy,
            successfulResponseBodyRetentionPolicy: BodyRetentionPolicy,
            validationErrorBodyRetentionPolicy: BodyRetentionPolicy,
            assumesHTTP3Capable: Bool?,
            requestIDGenerator: any RequestIDGenerator,
            requestAdapters: [AnyRequestAdapter],
            authenticationProvider: (any AuthenticationProvider)?,
        ) {
            self.baseURL = baseURL
            self.defaultHeaders = defaultHeaders
            self.defaultQueryItems = defaultQueryItems
            self.urlQueryEncoderConfiguration = urlQueryEncoderConfiguration
            self.jsonEncoderConfiguration = jsonEncoderConfiguration
            self.jsonDecoderConfiguration = jsonDecoderConfiguration
            self.urlCache = urlCache
            self.httpCookieStorage = httpCookieStorage
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
            self.waitsForConnectivity = waitsForConnectivity
            self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
            self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
            self.allowsCellularAccess = allowsCellularAccess
            self.cachePolicy = cachePolicy
            self.responseValidationPolicy = responseValidationPolicy
            self.retryPolicy = retryPolicy
            self.redirectPolicy = redirectPolicy
            self.successfulResponseBodyRetentionPolicy = successfulResponseBodyRetentionPolicy
            self.validationErrorBodyRetentionPolicy = validationErrorBodyRetentionPolicy
            self.assumesHTTP3Capable = assumesHTTP3Capable
            self.requestIDGenerator = requestIDGenerator
            self.requestAdapters = requestAdapters
            self.authenticationProvider = authenticationProvider
        }

        /// Returns a copy with replacement static query items for relative routes.
        ///
        /// - Parameter queryItems: The static client query items in caller-supplied order.
        /// - Returns: A configuration with the replacement default query layer.
        public func withDefaultQueryItems(_ queryItems: [URLQueryItem]) -> Self {
            copying(defaultQueryItems: .set(queryItems))
        }

        /// Returns a copy with replacement client-wide Codable query encoder defaults.
        ///
        /// - Parameter configuration: The strategy overrides used by future logical executions.
        /// - Returns: A configuration with the replacement encoder defaults.
        public func withURLQueryEncoderConfiguration(
            _ configuration: URLQueryEncoder.Configuration,
        ) -> Self {
            copying(urlQueryEncoderConfiguration: .set(configuration))
        }

        /// Returns a copy with replacement client-wide JSON encoder configuration.
        ///
        /// The closure is applied to a new library-owned `JSONEncoder` for every JSON body encoding.
        ///
        /// - Parameter configure: A Sendable closure that configures each fresh JSON encoder.
        /// - Returns: A configuration with the replacement JSON encoder configuration.
        public func withJSONEncoderConfiguration(
            _ configure: @escaping @Sendable (JSONEncoder) -> Void,
        ) -> Self {
            copying(jsonEncoderConfiguration: .set(configure))
        }

        /// Returns a copy with replacement client-wide JSON decoder configuration.
        ///
        /// The closure is applied to a new library-owned `JSONDecoder` for every JSON response decode.
        ///
        /// - Parameter configure: A Sendable closure that configures each fresh JSON decoder.
        /// - Returns: A configuration with the replacement JSON decoder configuration.
        public func withJSONDecoderConfiguration(
            _ configure: @escaping @Sendable (JSONDecoder) -> Void,
        ) -> Self {
            copying(jsonDecoderConfiguration: .set(configure))
        }

        /// Returns a copy that uses the supplied logical-execution identity generator.
        ///
        /// - Parameter generator: The synchronous, nonthrowing generator to use for future
        ///   logical executions created by the client.
        /// - Returns: A configuration with the replacement generator.
        public func withRequestIDGenerator(_ generator: any RequestIDGenerator) -> Self {
            copying(requestIDGenerator: .set(generator))
        }

        /// Returns a copy with one adapter appended to the client execution order.
        ///
        /// Adapters run after body preparation and receive the request returned by the previous
        /// adapter. Repeated calls append in call order.
        ///
        /// - Parameter adapter: The adapter to append.
        /// - Returns: A configuration with the adapter added after existing adapters.
        public func withRequestAdapter(_ adapter: some RequestAdapter) -> Self {
            copying(requestAdapters: .set(requestAdapters + [AnyRequestAdapter(adapter)]))
        }

        /// Returns a copy using the supplied authentication provider, or no provider when nil.
        ///
        /// - Parameter provider: The provider for endpoints that require authentication.
        /// - Returns: A configuration with the replacement optional provider.
        public func withAuthenticationProvider(_ provider: (any AuthenticationProvider)?) -> Self {
            copying(authenticationProvider: .set(provider))
        }

        /// Returns a copy with replacement client-wide default HTTP fields.
        ///
        /// - Parameter fields: The client defaults in caller-supplied order.
        /// - Returns: A configuration with the replacement client header layer.
        public func withDefaultHeaders(_ fields: HTTPFields) -> Self {
            copying(defaultHeaders: .set(fields))
        }

        /// Returns a copy using the supplied URL cache.
        ///
        /// A nil cache disables URL caching.
        public func withURLCache(_ urlCache: URLCache?) -> Self {
            copying(urlCache: .set(urlCache))
        }

        /// Returns a copy using the supplied cookie storage.
        ///
        /// A nil storage disables cookie storage.
        public func withHTTPCookieStorage(_ httpCookieStorage: HTTPCookieStorage?) -> Self {
            copying(httpCookieStorage: .set(httpCookieStorage))
        }

        /// Returns a copy using the supplied client request timeout.
        ///
        /// A nil timeout preserves Foundation's default. An explicit timeout must be greater than zero.
        public func withRequestTimeout(_ requestTimeout: Duration?) -> Self {
            copying(requestTimeout: .set(requestTimeout))
        }

        /// Returns a copy using the supplied client resource timeout.
        ///
        /// A nil timeout preserves Foundation's default. An explicit timeout must be greater than zero.
        public func withResourceTimeout(_ resourceTimeout: Duration?) -> Self {
            copying(resourceTimeout: .set(resourceTimeout))
        }

        /// Returns a copy with the supplied waits-for-connectivity setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withWaitsForConnectivity(_ waitsForConnectivity: Bool?) -> Self {
            copying(waitsForConnectivity: .set(waitsForConnectivity))
        }

        /// Returns a copy with the supplied expensive-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsExpensiveNetworkAccess(_ allowsExpensiveNetworkAccess: Bool?) -> Self {
            copying(allowsExpensiveNetworkAccess: .set(allowsExpensiveNetworkAccess))
        }

        /// Returns a copy with the supplied constrained-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsConstrainedNetworkAccess(_ allowsConstrainedNetworkAccess: Bool?) -> Self {
            copying(allowsConstrainedNetworkAccess: .set(allowsConstrainedNetworkAccess))
        }

        /// Returns a copy with the supplied cellular-network access setting.
        ///
        /// A nil value preserves Foundation's default.
        public func withAllowsCellularAccess(_ allowsCellularAccess: Bool?) -> Self {
            copying(allowsCellularAccess: .set(allowsCellularAccess))
        }

        /// Returns a copy with the supplied Foundation request cache policy.
        ///
        /// A nil policy preserves Foundation's default.
        public func withCachePolicy(_ cachePolicy: URLRequest.CachePolicy?) -> Self {
            copying(cachePolicy: .set(cachePolicy))
        }

        /// Returns a copy with a replacement response-validation policy.
        public func withResponseValidationPolicy(_ policy: ResponseValidationPolicy) -> Self {
            copying(responseValidationPolicy: .set(policy))
        }

        /// Returns a copy with a replacement client-wide retry policy.
        public func withRetryPolicy(_ policy: RetryPolicy) -> Self {
            copying(retryPolicy: .set(policy))
        }

        /// Returns a copy with a replacement client-wide redirect policy.
        public func withRedirectPolicy(_ policy: RedirectPolicy) -> Self {
            copying(redirectPolicy: .set(policy))
        }

        /// Returns a copy with a replacement accepted-response body-retention policy.
        public func withSuccessfulResponseBodyRetentionPolicy(_ policy: BodyRetentionPolicy) -> Self {
            copying(successfulResponseBodyRetentionPolicy: .set(policy))
        }

        /// Returns a copy with a replacement validation-error body-retention policy.
        public func withValidationErrorBodyRetentionPolicy(_ policy: BodyRetentionPolicy) -> Self {
            copying(validationErrorBodyRetentionPolicy: .set(policy))
        }

        /// Returns a copy with the supplied HTTP/3 first-attempt preference.
        ///
        /// A nil value leaves Foundation's generated URLRequest preference unchanged.
        public func withAssumesHTTP3Capable(_ assumesHTTP3Capable: Bool?) -> Self {
            copying(assumesHTTP3Capable: .set(assumesHTTP3Capable))
        }

        /// Returns an immutable copy with selected fields replaced.
        ///
        /// Fields marked unchanged keep their current values. A set update replaces the field,
        /// including when the replacement value is nil.
        private func copying(
            baseURL baseURLUpdate: ConfigurationFieldUpdate<URL?> = .unchanged,
            defaultHeaders defaultHeadersUpdate: ConfigurationFieldUpdate<HTTPFields> = .unchanged,
            defaultQueryItems defaultQueryItemsUpdate: ConfigurationFieldUpdate<[URLQueryItem]> = .unchanged,
            urlQueryEncoderConfiguration urlQueryEncoderConfigurationUpdate: ConfigurationFieldUpdate<URLQueryEncoder
                .Configuration> = .unchanged,
            jsonEncoderConfiguration jsonEncoderConfigurationUpdate: ConfigurationFieldUpdate<
                JSONEncoderConfiguration,
            > = .unchanged,
            jsonDecoderConfiguration jsonDecoderConfigurationUpdate: ConfigurationFieldUpdate<
                JSONDecoderConfiguration,
            > = .unchanged,
            urlCache urlCacheUpdate: ConfigurationFieldUpdate<URLCache?> = .unchanged,
            httpCookieStorage httpCookieStorageUpdate: ConfigurationFieldUpdate<HTTPCookieStorage?> = .unchanged,
            requestTimeout requestTimeoutUpdate: ConfigurationFieldUpdate<Duration?> = .unchanged,
            resourceTimeout resourceTimeoutUpdate: ConfigurationFieldUpdate<Duration?> = .unchanged,
            waitsForConnectivity waitsForConnectivityUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            allowsExpensiveNetworkAccess allowsExpensiveNetworkAccessUpdate: ConfigurationFieldUpdate<Bool?> =
                .unchanged,
            allowsConstrainedNetworkAccess allowsConstrainedNetworkAccessUpdate: ConfigurationFieldUpdate<Bool?> =
                .unchanged,
            allowsCellularAccess allowsCellularAccessUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            cachePolicy cachePolicyUpdate: ConfigurationFieldUpdate<URLRequest.CachePolicy?> = .unchanged,
            responseValidationPolicy responseValidationPolicyUpdate: ConfigurationFieldUpdate<
                ResponseValidationPolicy,
            > = .unchanged,
            retryPolicy retryPolicyUpdate: ConfigurationFieldUpdate<RetryPolicy> = .unchanged,
            redirectPolicy redirectPolicyUpdate: ConfigurationFieldUpdate<RedirectPolicy> = .unchanged,
            successfulResponseBodyRetentionPolicy successfulResponseBodyRetentionPolicyUpdate: ConfigurationFieldUpdate<
                BodyRetentionPolicy,
            > = .unchanged,
            validationErrorBodyRetentionPolicy validationErrorBodyRetentionPolicyUpdate: ConfigurationFieldUpdate<
                BodyRetentionPolicy,
            > = .unchanged,
            assumesHTTP3Capable assumesHTTP3CapableUpdate: ConfigurationFieldUpdate<Bool?> = .unchanged,
            requestIDGenerator requestIDGeneratorUpdate: ConfigurationFieldUpdate<any RequestIDGenerator> = .unchanged,
            requestAdapters requestAdaptersUpdate: ConfigurationFieldUpdate<[AnyRequestAdapter]> = .unchanged,
            authenticationProvider authenticationProviderUpdate: ConfigurationFieldUpdate<
                (any AuthenticationProvider)?,
            > = .unchanged,
        ) -> Self {
            Self(
                baseURL: baseURLUpdate.applying(to: baseURL),
                defaultHeaders: defaultHeadersUpdate.applying(to: defaultHeaders),
                defaultQueryItems: defaultQueryItemsUpdate.applying(to: defaultQueryItems),
                urlQueryEncoderConfiguration: urlQueryEncoderConfigurationUpdate.applying(
                    to: urlQueryEncoderConfiguration,
                ),
                jsonEncoderConfiguration: jsonEncoderConfigurationUpdate.applying(
                    to: jsonEncoderConfiguration,
                ),
                jsonDecoderConfiguration: jsonDecoderConfigurationUpdate.applying(
                    to: jsonDecoderConfiguration,
                ),
                urlCache: urlCacheUpdate.applying(to: urlCache),
                httpCookieStorage: httpCookieStorageUpdate.applying(to: httpCookieStorage),
                requestTimeout: requestTimeoutUpdate.applying(to: requestTimeout),
                resourceTimeout: resourceTimeoutUpdate.applying(to: resourceTimeout),
                waitsForConnectivity: waitsForConnectivityUpdate.applying(to: waitsForConnectivity),
                allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccessUpdate.applying(
                    to: allowsExpensiveNetworkAccess,
                ),
                allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccessUpdate.applying(
                    to: allowsConstrainedNetworkAccess,
                ),
                allowsCellularAccess: allowsCellularAccessUpdate.applying(to: allowsCellularAccess),
                cachePolicy: cachePolicyUpdate.applying(to: cachePolicy),
                responseValidationPolicy: responseValidationPolicyUpdate.applying(to: responseValidationPolicy),
                retryPolicy: retryPolicyUpdate.applying(to: retryPolicy),
                redirectPolicy: redirectPolicyUpdate.applying(to: redirectPolicy),
                successfulResponseBodyRetentionPolicy: successfulResponseBodyRetentionPolicyUpdate.applying(
                    to: successfulResponseBodyRetentionPolicy,
                ),
                validationErrorBodyRetentionPolicy: validationErrorBodyRetentionPolicyUpdate.applying(
                    to: validationErrorBodyRetentionPolicy,
                ),
                assumesHTTP3Capable: assumesHTTP3CapableUpdate.applying(to: assumesHTTP3Capable),
                requestIDGenerator: requestIDGeneratorUpdate.applying(to: requestIDGenerator),
                requestAdapters: requestAdaptersUpdate.applying(to: requestAdapters),
                authenticationProvider: authenticationProviderUpdate.applying(to: authenticationProvider),
            )
        }
    }

    private let transport: any NetworkTransport
    private let configuration: Configuration
    private let retryTimingDependencies: RetryTimingDependencies

    /// Creates a client that owns a foreground URL session for its requests.
    public convenience init() {
        let defaultConfiguration = Configuration()
        do {
            try Self.validate(defaultConfiguration)
        } catch {
            preconditionFailure("The default NetworkClient configuration must be valid.")
        }
        self.init(
            validatedTransport: URLSessionTransport(configuration: defaultConfiguration),
            configuration: defaultConfiguration,
            retryTimingDependencies: .live,
        )
    }

    /// Creates a client from an immutable configuration and its owned foreground URL session.
    ///
    /// - Parameter configuration: The configuration used for logical request executions.
    public convenience init(configuration: Configuration) throws {
        try Self.validate(configuration)
        self.init(
            validatedTransport: URLSessionTransport(configuration: configuration),
            configuration: configuration,
            retryTimingDependencies: .live,
        )
    }

    /// Creates a client that owns a foreground URL session and uses the supplied base URL.
    ///
    /// - Parameter baseURL: The HTTP or HTTPS base URL used for relative routes. It must not
    ///   contain a query or fragment.
    public convenience init(baseURL: URL?) throws {
        try self.init(configuration: Configuration(baseURL: baseURL))
    }

    package convenience init(
        transport: any NetworkTransport,
        configuration: Configuration = .init(),
        retryTimingDependencies: RetryTimingDependencies = .live,
    ) throws {
        try Self.validate(configuration)
        self.init(
            validatedTransport: transport,
            configuration: configuration,
            retryTimingDependencies: retryTimingDependencies,
        )
    }

    private init(
        validatedTransport transport: any NetworkTransport,
        configuration: Configuration,
        retryTimingDependencies: RetryTimingDependencies,
    ) {
        self.transport = transport
        self.configuration = configuration
        self.retryTimingDependencies = retryTimingDependencies
    }

    /// Starts a shared logical execution immediately.
    ///
    /// - Parameter request: The immutable endpoint invocation to execute.
    /// - Returns: A shared task whose value is produced by exactly one execution.
    public func task<Output: Sendable>(for request: Request<Output>) -> NetworkTask<Output> {
        let requestID = configuration.requestIDGenerator.generateRequestID()
        let networkTransport = transport
        let timingDependencies = retryTimingDependencies
        let baseURL = configuration.baseURL
        let clientDefaultHeaders = configuration.defaultHeaders
        let clientQueryItems = configuration.defaultQueryItems
        let clientEncoderConfiguration = configuration.urlQueryEncoderConfiguration
        let clientJSONEncoderConfiguration = configuration.jsonEncoderConfiguration
        let clientJSONDecoderConfiguration = configuration.jsonDecoderConfiguration
        let clientResponseValidationPolicy = configuration.responseValidationPolicy
        let retryPolicy = request.retryPolicy ?? configuration.retryPolicy
        let redirectPolicy = request.redirectPolicy ?? configuration.redirectPolicy
        let clientSuccessfulResponseBodyRetentionPolicy = configuration.successfulResponseBodyRetentionPolicy
        let clientValidationErrorBodyRetentionPolicy = configuration.validationErrorBodyRetentionPolicy
        let requestAdapters = configuration.requestAdapters
        let authenticationProvider = configuration.authenticationProvider
        let routeKind: QueryRouteKind =
            switch request.route {
            case .absolute:
                .absolute
            case .relative:
                .relative
            }

        return NetworkTask(requestID: requestID) { progress in
            let routeURL = try Self.preflightURL(for: request.route, baseURL: baseURL, requestID: requestID)
            let url = try QueryComposer.compose(
                url: routeURL,
                routeKind: routeKind,
                clientQueryItems: clientQueryItems,
                clientEncoderConfiguration: clientEncoderConfiguration,
                endpointQuery: request.query,
                requestQueryItems: request.requestQueryItems,
                requestID: requestID,
            )
            let authentication = try resolveAuthenticationConfiguration(
                requirement: request.authenticationRequirement,
                provider: authenticationProvider,
                requestID: requestID,
            )
            var attempts: [AttemptMetrics] = []
            var attemptNumber: UInt = 0
            var retryCount: UInt = 0
            var authenticationReplayCount: UInt = 0

            while true {
                try Task.checkCancellation()

                let preparedBody = try request.body?.prepare(
                    clientJSONEncoderConfiguration: clientJSONEncoderConfiguration,
                    endpointJSONEncoderConfiguration: request.jsonEncoderConfiguration,
                ) ?? .none
                let bodyInspection = preparedBody.inspection
                guard let execution = TransportExecution.resolve(
                    operation: request.operation,
                    body: bodyInspection,
                ) else {
                    throw RequestConstructionError(
                        requestID: requestID,
                        reason: .unsupportedOperationBodyCombination,
                    )
                }

                if case let .uploadFromFile(fileURL) = execution {
                    try validateFileBody(fileURL, requestID: requestID)
                }

                var inferredHeaders = preparedBody.inferredHeaders
                if let inferredAccept = request.response.inferredAccept {
                    inferredHeaders[fields: .accept] = [HTTPField(name: .accept, value: inferredAccept)]
                }
                let headerFields = HeaderComposer.compose(
                    libraryInferred: inferredHeaders,
                    clientDefaults: clientDefaultHeaders,
                    endpoint: request.endpointHeaders,
                    request: request.requestHeaders,
                )
                let httpRequest = HTTPRequest(method: request.method, url: url, headerFields: headerFields)
                let adaptedRequest = try await adaptRequestForAttempt(
                    httpRequest,
                    body: bodyInspection,
                    requestID: requestID,
                    context: request.context,
                    adapters: requestAdapters,
                    authentication: authentication,
                )

                try Task.checkCancellation()
                let nextAttemptNumber = attemptNumber + 1
                let transportRequest = TransportRequest(
                    httpRequest: adaptedRequest,
                    body: bodyInspection,
                    redirectPolicy: redirectPolicy,
                    requestID: requestID,
                    requestContext: request.context,
                    attemptNumber: nextAttemptNumber,
                    operation: request.operation,
                    execution: execution,
                )
                let transportResult = await executeTransportAttempt(
                    using: networkTransport,
                    request: transportRequest,
                    progress: progress,
                )

                switch transportResult {
                case let .redirectLimitExceeded(maximumRedirects, lastResponse, rawTaskMetrics):
                    attemptNumber = nextAttemptNumber
                    let normalizedMetrics = NormalizedAttemptMetrics(taskMetrics: rawTaskMetrics)
                    attempts.append(
                        AttemptMetrics(
                            requestID: requestID,
                            attemptNumber: attemptNumber,
                            normalizedMetrics: normalizedMetrics,
                            outcome: .redirectLimitExceeded,
                            diagnosticReason: "redirect limit exceeded",
                            rawTaskMetrics: rawTaskMetrics,
                        ),
                    )
                    throw RedirectError.tooManyRedirects(
                        requestID: requestID,
                        maximumRedirects: maximumRedirects,
                        lastResponse: lastResponse,
                        attempts: attempts,
                    )

                case let .success(body: successfulBody, response: httpResponse, rawTaskMetrics):
                    attemptNumber = nextAttemptNumber
                    let normalizedMetrics = NormalizedAttemptMetrics(taskMetrics: rawTaskMetrics)
                    try Task.checkCancellation()

                    if let replayAttempt = try await authenticationReplayAttempt(
                        authentication: authentication,
                        replayCount: authenticationReplayCount,
                        request: adaptedRequest,
                        response: httpResponse,
                        receivedBody: successfulBody.receivedResponseBody,
                        requestContext: request.context,
                        requestID: requestID,
                        attemptNumber: attemptNumber,
                        normalizedMetrics: normalizedMetrics,
                        rawTaskMetrics: rawTaskMetrics,
                    ) {
                        successfulBody.discardFile()
                        attempts.append(replayAttempt)
                        authenticationReplayCount += 1
                        try Task.checkCancellation()
                        continue
                    }

                    let classification = retryPolicy.builtInClassification(
                        method: adaptedRequest.method,
                        response: httpResponse,
                    )
                    let retryContext = RetryPolicy.Context(
                        builtInDecision: classification.decision,
                        builtInReason: classification.reason,
                        method: adaptedRequest.method,
                        response: httpResponse,
                        transportError: nil,
                        context: request.context,
                        requestID: requestID,
                        attemptNumber: attemptNumber,
                        retryCount: retryCount,
                    )
                    try Task.checkCancellation()
                    let retryResolution = resolveRetryDecision(
                        policy: retryPolicy,
                        context: retryContext,
                        retryCount: retryCount,
                    )
                    try Task.checkCancellation()

                    if let retryResolution, retryResolution.shouldRetry {
                        attempts.append(
                            AttemptMetrics(
                                requestID: requestID,
                                attemptNumber: attemptNumber,
                                normalizedMetrics: normalizedMetrics,
                                outcome: .retryScheduled,
                                diagnosticReason: retryResolution.customDecision == .retry
                                    ? "custom retry decision: \(classification.reason)"
                                    : "built-in retry decision: \(classification.reason)",
                                rawTaskMetrics: rawTaskMetrics,
                            ),
                        )
                        let localDelay = RetryTiming.localDelay(
                            strategy: retryPolicy.backoffStrategy,
                            retryCount: retryCount,
                            randomUnit: timingDependencies.randomUnit,
                        )
                        let delay = RetryTiming.resolve(
                            localDelay: localDelay,
                            retryAfterValue: httpResponse.headerFields[.retryAfter],
                            policy: retryPolicy.retryAfterPolicy,
                            maximumServerDelay: retryPolicy.maximumRetryAfterDelay,
                            now: timingDependencies.now(),
                        )
                        successfulBody.discardFile()
                        try await RetryTiming.sleepIfNeeded(delay, using: timingDependencies.sleep)
                        retryCount += 1
                        continue
                    }

                    let validationContext = ResponseValidationContext(
                        httpResponse: httpResponse,
                        receivedBody: successfulBody.receivedResponseBody,
                        requestID: requestID,
                        requestContext: request.context,
                    )
                    let validationPolicy = request.responseValidationPolicy ?? clientResponseValidationPolicy
                    switch validationPolicy.validate(validationContext) {
                    case .accept:
                        attempts.append(
                            AttemptMetrics(
                                requestID: requestID,
                                attemptNumber: attemptNumber,
                                normalizedMetrics: normalizedMetrics,
                                outcome: .acceptedResponse,
                                diagnosticReason: nil,
                                rawTaskMetrics: rawTaskMetrics,
                            ),
                        )
                    case let .reject(reason):
                        attempts.append(
                            AttemptMetrics(
                                requestID: requestID,
                                attemptNumber: attemptNumber,
                                normalizedMetrics: normalizedMetrics,
                                outcome: .validationRejection,
                                diagnosticReason: reason,
                                rawTaskMetrics: rawTaskMetrics,
                            ),
                        )
                        let retentionPolicy = request.validationErrorBodyRetentionPolicy
                            ?? clientValidationErrorBodyRetentionPolicy
                        let retainedBody = try successfulBody.retainedBody(using: retentionPolicy)
                        successfulBody.discardFile()
                        throw ResponseValidationError(
                            httpResponse: httpResponse,
                            retainedBody: retainedBody,
                            requestID: requestID,
                            attempts: attempts,
                            reason: reason,
                        )
                    }

                    try Task.checkCancellation()
                    try finalizeSuccessfulDownload(
                        body: successfulBody,
                        destination: request.downloadDestination,
                        response: httpResponse,
                        context: request.context,
                    )

                    let value = try makeSuccessfulResponseValue(
                        responseHandling: request.response,
                        body: successfulBody,
                        response: httpResponse,
                        clientJSONDecoderConfiguration: clientJSONDecoderConfiguration,
                        endpointJSONDecoderConfiguration: request.jsonDecoderConfiguration,
                    )
                    let retentionPolicy = request.successfulResponseBodyRetentionPolicy
                        ?? clientSuccessfulResponseBodyRetentionPolicy
                    let retainedBody = successfulBody.retainedBodyForAcceptedResponse(using: retentionPolicy)
                    return Response(
                        value: value,
                        httpResponse: httpResponse,
                        requestID: requestID,
                        attempts: attempts,
                        retainedBody: retainedBody,
                    )

                case let .failure(error, rawTaskMetrics, didStartTask):
                    guard didStartTask else {
                        throw error
                    }

                    attemptNumber = nextAttemptNumber
                    let normalizedMetrics = NormalizedAttemptMetrics(taskMetrics: rawTaskMetrics)
                    if error is CancellationError {
                        attempts.append(
                            AttemptMetrics(
                                requestID: requestID,
                                attemptNumber: attemptNumber,
                                normalizedMetrics: normalizedMetrics,
                                outcome: .transportFailure,
                                diagnosticReason: String(describing: error),
                                rawTaskMetrics: rawTaskMetrics,
                            ),
                        )
                        throw CancellationError()
                    }

                    try Task.checkCancellation()

                    let classification = retryPolicy.builtInClassification(
                        method: adaptedRequest.method,
                        transportError: error,
                    )
                    let retryContext = RetryPolicy.Context(
                        builtInDecision: classification.decision,
                        builtInReason: classification.reason,
                        method: adaptedRequest.method,
                        response: nil,
                        transportError: error,
                        context: request.context,
                        requestID: requestID,
                        attemptNumber: attemptNumber,
                        retryCount: retryCount,
                    )
                    try Task.checkCancellation()
                    let retryResolution = resolveRetryDecision(
                        policy: retryPolicy,
                        context: retryContext,
                        retryCount: retryCount,
                    )
                    try Task.checkCancellation()

                    let shouldRetry = retryResolution?.shouldRetry == true
                    let diagnosticReason: String =
                        if let retryResolution, retryResolution.shouldRetry {
                            transportFailureRetryDiagnosticReason(
                                error: error,
                                classificationReason: classification.reason,
                                wasForcedByCustomDecision: retryResolution.wasForcedByCustomDecision,
                            )
                        } else {
                            String(describing: error)
                        }
                    attempts.append(
                        AttemptMetrics(
                            requestID: requestID,
                            attemptNumber: attemptNumber,
                            normalizedMetrics: normalizedMetrics,
                            outcome: .transportFailure,
                            diagnosticReason: diagnosticReason,
                            rawTaskMetrics: rawTaskMetrics,
                        ),
                    )

                    guard shouldRetry else {
                        throw error
                    }

                    let localDelay = RetryTiming.localDelay(
                        strategy: retryPolicy.backoffStrategy,
                        retryCount: retryCount,
                        randomUnit: timingDependencies.randomUnit,
                    )
                    let delay = RetryTiming.resolve(
                        localDelay: localDelay,
                        retryAfterValue: nil,
                        policy: retryPolicy.retryAfterPolicy,
                        maximumServerDelay: retryPolicy.maximumRetryAfterDelay,
                        now: timingDependencies.now(),
                    )
                    try await RetryTiming.sleepIfNeeded(delay, using: timingDependencies.sleep)
                    retryCount += 1
                }
            }
        }
    }

    /// Executes a request and returns its decoded value and HTTP response.
    ///
    /// Transport and decoding errors are propagated unchanged.
    ///
    /// - Parameter request: The immutable endpoint invocation to execute.
    /// - Returns: The decoded response and its HTTP metadata.
    public func send<Output: Sendable>(_ request: Request<Output>) async throws -> Response<Output> {
        let task = task(for: request)

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private static func validate(_ configuration: Configuration) throws {
        var failures: [ConfigurationError.Failure] = []

        if let baseURL = configuration.baseURL {
            if let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                let scheme = components.scheme?.lowercased()
                if scheme != "http", scheme != "https" {
                    failures.append(.baseURLScheme)
                }
                if components.percentEncodedQuery != nil {
                    failures.append(.baseURLQuery)
                }
                if components.percentEncodedFragment != nil {
                    failures.append(.baseURLFragment)
                }
            } else {
                failures.append(.baseURLScheme)
            }
        }

        if let requestTimeout = configuration.requestTimeout, requestTimeout <= .zero {
            failures.append(.requestTimeout)
        }
        if let resourceTimeout = configuration.resourceTimeout, resourceTimeout <= .zero {
            failures.append(.resourceTimeout)
        }

        guard failures.isEmpty else {
            throw ConfigurationError(failures: failures)
        }
    }

    private static func preflightURL(
        for route: ResolvedEndpointRoute,
        baseURL: URL?,
        requestID: RequestID,
    ) throws -> URL {
        switch route {
        case let .absolute(url):
            return try absoluteURL(url, requestID: requestID)
        case let .relative(pathComponents):
            guard let baseURL else {
                throw RequestConstructionError(
                    requestID: requestID,
                    reason: .relativeRouteRequiresBaseURL,
                )
            }

            return try relativeURL(pathComponents, baseURL: baseURL, requestID: requestID)
        }
    }

    private static func absoluteURL(_ url: URL, requestID: RequestID) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard let scheme = components.scheme else {
            throw RequestConstructionError(requestID: requestID, reason: .missingURLScheme)
        }
        guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else {
            throw RequestConstructionError(
                requestID: requestID,
                reason: .unsupportedURLScheme(scheme),
            )
        }
        guard let host = components.host, !host.isEmpty else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        components.fragment = nil
        guard let resolvedURL = components.url else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return resolvedURL
    }

    private static func relativeURL(
        _ pathComponents: [String],
        baseURL: URL,
        requestID: RequestID,
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard let host = components.host, !host.isEmpty else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }
        guard !pathComponents.isEmpty else {
            return baseURL
        }

        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        } else if !path.hasSuffix("/") {
            path.append("/")
        }

        let encodedComponents = try pathComponents.map { component in
            try percentEncodePathComponent(component, requestID: requestID)
        }
        components.percentEncodedPath = path + encodedComponents.joined(separator: "/")

        guard let resolvedURL = components.url else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return resolvedURL
    }

    private static func percentEncodePathComponent(_ component: String, requestID: RequestID) throws -> String {
        if component == "." {
            return "%2E"
        }
        if component == ".." {
            return "%2E%2E"
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@",
        )

        guard let encodedComponent = component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw RequestConstructionError(requestID: requestID, reason: .urlCompositionFailed)
        }

        return encodedComponent
    }
}
