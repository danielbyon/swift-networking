//
//  NetworkLoggerTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import os
import Testing
@testable import Networking

@Suite("Network logger diagnostics")
struct NetworkLoggerTests {
    @Test("The observer can be registered through immutable client configuration")
    func observerRegistersThroughClientConfiguration() {
        let networkLogger = NetworkLogger(logger: Logger(subsystem: "test", category: "network"))
        let configuration = NetworkClient.Configuration().withEventObserver(networkLogger.eventObserver)

        #expect(configuration.eventObservers.count == 1)
    }

    @Test("Every lifecycle event produces a named diagnostic")
    func everyLifecycleEventProducesADiagnostic() {
        let requestID = makeRequestID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let context = RequestContext()
        let request = makeRequest()
        let response = makeResponse()
        let metrics = NormalizedAttemptMetrics(duration: .milliseconds(12))
        let attempts = [
            AttemptMetrics(
                requestID: requestID,
                attemptNumber: 1,
                normalizedMetrics: metrics,
                outcome: .acceptedResponse,
                diagnosticReason: nil,
                rawTaskMetrics: nil,
            ),
        ]
        let events: [(String, NetworkEvent)] = [
            (
                "request_started",
                .requestStarted(RequestStartedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                )),
            ),
            (
                "attempt_started",
                .attemptStarted(AttemptStartedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    request: request,
                )),
            ),
            (
                "response_received",
                .responseReceived(ResponseReceivedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    request: request,
                    httpResponse: response,
                    normalizedMetrics: metrics,
                    rawTaskMetrics: nil,
                )),
            ),
            (
                "attempt_failed",
                .attemptFailed(AttemptFailedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    request: request,
                    httpResponse: response,
                    error: TestSecretError(),
                    normalizedMetrics: metrics,
                    rawTaskMetrics: nil,
                )),
            ),
            (
                "authentication_replay_scheduled",
                .authenticationReplayScheduled(AuthenticationReplayScheduledEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    request: request,
                    httpResponse: response,
                    normalizedMetrics: metrics,
                    rawTaskMetrics: nil,
                )),
            ),
            (
                "retry_scheduled",
                .retryScheduled(RetryScheduledEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    request: request,
                    httpResponse: response,
                    transportError: nil,
                    delay: .seconds(2),
                    normalizedMetrics: metrics,
                    rawTaskMetrics: nil,
                )),
            ),
            (
                "redirect_decision",
                .redirectDecision(RedirectDecisionEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    attemptNumber: 1,
                    redirectOrdinal: 1,
                    httpResponse: response,
                    proposedRequest: request,
                    decision: .reject,
                )),
            ),
            (
                "request_completed",
                .requestCompleted(RequestCompletedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    httpResponse: response,
                    attempts: attempts,
                )),
            ),
            (
                "request_failed",
                .requestFailed(RequestFailedEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                    error: TestSecretError(),
                )),
            ),
            (
                "request_cancelled",
                .requestCancelled(RequestCancelledEvent(
                    requestID: requestID,
                    timestamp: timestamp,
                    requestContext: context,
                )),
            ),
        ]
        let formatter = NetworkLoggerFormatter(configuration: .init())

        for (expectedName, event) in events {
            #expect(formatter.format(event).message.contains("event=\(expectedName)"))
        }
    }

    @Test("Request URLs, URL headers, and sensitive headers are sanitized")
    func requestAndHeaderValuesAreSanitized() {
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 2,
            request: makeRequest(),
        ))
        let formatter = NetworkLoggerFormatter(configuration: .init(
            additionalSensitiveHeaders: ["X-Api-Key"],
        ))

        let message = formatter.format(event).message

        #expect(message.contains("method=POST"))
        #expect(message.contains("https://example.com:8443/v1"))
        #expect(message.contains("token=<redacted>"))
        #expect(message.contains("empty=<redacted>"))
        #expect(message.contains("encoded=<redacted>"))
        #expect(message.contains("?token=<redacted>&empty=<redacted>&encoded=<redacted>&token=<redacted>"))
        #expect(!message.contains("ENCODED%2BQUERY%2DSECRET"))
        #expect(!message.contains("ENCODED+QUERY-SECRET"))
        #expect(message.contains("location=\"https://redirect.example/next?continue=<redacted>\""))
        #expect(message.contains("accept=application/json"))
        #expect(!message.contains("userinfo"))
        #expect(!message.contains("password"))
        #expect(!message.contains("QUERY-SECRET"))
        #expect(!message.contains("SECOND-QUERY-SECRET"))
        #expect(!message.contains("HEADER-QUERY-SECRET"))
        #expect(!message.contains("AUTH-SECRET"))
        #expect(!message.contains("COOKIE-SECRET"))
        #expect(!message.contains("SET-COOKIE-SECRET"))
        #expect(!message.contains("API-KEY-SECRET"))
    }

    @Test("Sensitive header names are matched case-insensitively")
    func sensitiveHeaderNamesAreMatchedCaseInsensitively() {
        var headers = HTTPFields()
        headers[.authorization] = "AUTHORIZATION-CASE-SECRET"

        let rendered = NetworkPrivacySanitizer.headers(
            headers,
            sensitiveHeaderNames: ["AUTHORIZATION"],
        )

        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains("AUTHORIZATION-CASE-SECRET"))
    }

    @Test("Header and context values cannot inject diagnostic fields")
    func freeFormValuesEscapeDiagnosticDelimiters() {
        let unsafeValue = "trace value=one,context=[spoofed]"
        let escapedValue = #"trace\svalue\=one\,context\=\[spoofed\]"#
        var headers = HTTPFields()
        headers[.accept] = unsafeValue
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/safe",
            headerFields: headers,
        )
        let context = RequestContext().setting(TraceContextKey.self, value: unsafeValue)
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: context,
            attemptNumber: 1,
            request: request,
        ))
        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("accept=\(escapedValue)"))
        #expect(message.contains("=\(escapedValue)]"))
        #expect(!message.contains(unsafeValue))
    }

    @Test("Query names cannot inject diagnostic delimiters")
    func queryNamesEscapeDiagnosticDelimiters() {
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/safe?name,][]=QUERY-KEY-SECRET",
        )
        let rendered = NetworkPrivacySanitizer.requestURLShape(request)

        #expect(rendered.contains("?name%2C%5D%5B%5D=<redacted>"))
        #expect(!rendered.contains("name,"))
        #expect(!rendered.contains("QUERY-KEY-SECRET"))
    }

    @Test("Metrics are included only when normalized values exist")
    func metricsUseOnlyAvailableNormalizedValues() {
        let requestID = makeRequestID()
        let event = NetworkEvent.responseReceived(ResponseReceivedEvent(
            requestID: requestID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: makeRequest(),
            httpResponse: makeResponse(),
            normalizedMetrics: NormalizedAttemptMetrics(
                duration: .milliseconds(25),
                transactions: [AttemptTransactionMetrics(
                    requestBodyBytesSent: 12,
                    responseBodyBytesReceived: 34,
                    networkProtocolName: nil,
                    isReusedConnection: nil,
                    resourceFetchType: nil,
                )],
            ),
            rawTaskMetrics: nil,
        ))
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let message = formatter.format(event).message

        #expect(message.contains("duration=0.025s"))
        #expect(message.contains("request_bytes=12"))
        #expect(message.contains("response_bytes=34"))
        #expect(!message.contains("redirect_count="))
        #expect(!message.contains("protocol="))
    }

    @Test("Retry diagnostics use the resolved delay and redirect diagnostics use the decision")
    func retryAndRedirectUseResolvedValues() {
        let requestID = makeRequestID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let context = RequestContext()
        let request = makeRequest()
        let response = makeResponse()
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let retry = formatter.format(.retryScheduled(RetryScheduledEvent(
            requestID: requestID,
            timestamp: timestamp,
            requestContext: context,
            attemptNumber: 2,
            request: request,
            httpResponse: response,
            transportError: nil,
            delay: .milliseconds(275),
            normalizedMetrics: NormalizedAttemptMetrics(),
            rawTaskMetrics: nil,
        )))
        let redirect = formatter.format(.redirectDecision(RedirectDecisionEvent(
            requestID: requestID,
            timestamp: timestamp,
            requestContext: context,
            attemptNumber: 2,
            redirectOrdinal: 3,
            httpResponse: response,
            proposedRequest: request,
            decision: .reject,
        )))

        #expect(retry.message.contains("delay=0.275s"))
        #expect(redirect.message.contains("redirect_ordinal=3"))
        #expect(redirect.message.contains("decision=reject"))
    }

    @Test("Request context output includes only opted-in values in stable order")
    func diagnosticContextIsOptInAndStable() {
        let requestID = makeRequestID()
        let context = RequestContext()
            .setting(PrivateContextKey.self, value: "PRIVATE-CONTEXT-SECRET")
            .setting(TraceContextKey.self, value: "trace-123")
            .setting(SecondTraceContextKey.self, value: "span-456")
        let event = NetworkEvent.requestStarted(RequestStartedEvent(
            requestID: requestID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: context,
        ))
        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("trace-123"))
        #expect(message.contains("span-456"))
        #expect(!message.contains("PRIVATE-CONTEXT-SECRET"))
        let reversedContext = RequestContext()
            .setting(SecondTraceContextKey.self, value: "span-456")
            .setting(TraceContextKey.self, value: "trace-123")
            .setting(PrivateContextKey.self, value: "PRIVATE-CONTEXT-SECRET")
        let reversedEvent = NetworkEvent.requestStarted(RequestStartedEvent(
            requestID: requestID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: reversedContext,
        ))
        let reversedMessage = NetworkLoggerFormatter(configuration: .init()).format(reversedEvent).message
        #expect(message == reversedMessage)
    }

    @Test("Body diagnostics are absent by default, including validation reason text")
    func bodyAndValidationReasonAreAbsentByDefault() {
        let body = RetainedBody(data: Data("RESPONSE-BODY-SECRET".utf8), originalByteCount: 40)
        let error = makeValidationError(body: body, reason: "VALIDATION-REASON-SECRET")
        let event = requestFailedEvent(error: error)
        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message
        let errorDescription = error.errorDescription ?? ""

        #expect(!message.contains("RESPONSE-BODY-SECRET"))
        #expect(!message.contains("VALIDATION-REASON-SECRET"))
        #expect(!errorDescription.contains("RESPONSE-BODY-SECRET"))
        #expect(!errorDescription.contains("VALIDATION-REASON-SECRET"))
        #expect(error.reason == "VALIDATION-REASON-SECRET")
    }

    @Test("Opt-in UTF-8 diagnostics respect the cap and trim at a scalar boundary")
    func byteCappedTextKeepsValidUTF8Prefix() {
        let original = Data("A🦄B".utf8)
        let error = makeValidationError(
            body: RetainedBody(data: original, originalByteCount: Int64(original.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 3),
        ))
        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("A"))
        #expect(message.contains("truncated=true"))
        #expect(!message.contains("🦄"))
        #expect(!message.contains("body=binary"))
    }

    @Test("Opt-in non-UTF-8 diagnostics describe bytes without dumping them")
    func binaryBodyIsDescribedStructurally() {
        let bytes = Data([0x00, 0xff, 0xfe, 0x61])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 4),
        ))
        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=binary"))
        #expect(message.contains("retained_bytes=4"))
        #expect(!message.contains("\u{FFFD}"))
    }

    @Test("Unknown errors use structural identity instead of their free-form description")
    func unknownErrorDescriptionIsNotLogged() {
        let event = requestFailedEvent(error: TestSecretError())
        let diagnostic = NetworkLoggerFormatter(configuration: .init()).format(event)

        #expect(diagnostic.message.contains("TestSecretError"))
        #expect(!diagnostic.message.contains("ARBITRARY-ERROR-SECRET"))
        #expect(diagnostic.level == .error)
    }

    @Test("Library-owned localized error descriptions redact header and URL query values")
    func libraryOwnedErrorDescriptionsUseSafeRendering() throws {
        let requestID = makeRequestID()
        let responseError = makeValidationError(
            body: nil,
            reason: "ARBITRARY-VALIDATION-SECRET",
        )
        let redirectError = RedirectError.tooManyRedirects(
            requestID: requestID,
            maximumRedirects: 2,
            lastResponse: makeResponse(),
            attempts: [],
        )
        let sourceSecret = "FILE-SOURCE-SECRET"
        let destinationSecret = "FILE-DESTINATION-SECRET"
        let source = try #require(URL(string: "file:///private/source?token=\(sourceSecret)"))
        let destination = try #require(URL(string: "file:///private/destination?token=\(destinationSecret)"))
        let downloadError = DownloadFileError.moveFailed(
            source: source,
            destination: destination,
            underlyingError: TestSecretError(),
        )
        let filesystemError = NSError(
            domain: "com.example.filesystem",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "ARBITRARY-FILESYSTEM-SECRET"],
        )
        let finalizationError = DownloadFileError.finalizationFailed(
            source: source,
            destination: destination,
            underlyingError: filesystemError,
        )
        let removalError = DownloadFileError.removeFailed(url: source, underlyingError: filesystemError)
        let descriptions = [
            RequestConstructionError(requestID: requestID, reason: .unsupportedURLScheme("https"))
                .errorDescription ?? "",
            responseError.errorDescription ?? "",
            redirectError.errorDescription ?? "",
            downloadError.errorDescription ?? "",
            finalizationError.errorDescription ?? "",
            removalError.errorDescription ?? "",
        ].joined(separator: "\n")
        let downloadDescription = downloadError.errorDescription ?? ""

        #expect(descriptions.contains("set-cookie=<redacted>"))
        #expect(descriptions.contains("token=<redacted>"))
        #expect(downloadDescription.contains("source=file:///private/source?token=<redacted>"))
        #expect(downloadDescription.contains("destination=file:///private/destination?token=<redacted>"))
        #expect(!descriptions.contains("SET-COOKIE-SECRET"))
        #expect(!descriptions.contains("HEADER-QUERY-SECRET"))
        #expect(!descriptions.contains(sourceSecret))
        #expect(!descriptions.contains(destinationSecret))
        #expect(!descriptions.contains("ARBITRARY-VALIDATION-SECRET"))
        #expect(!descriptions.contains("ARBITRARY-ERROR-SECRET"))
        #expect(!descriptions.contains("ARBITRARY-FILESYSTEM-SECRET"))
        #expect(descriptions.contains("domain=<redacted>"))
        #expect(descriptions.contains("code=13"))
        #expect(responseError.reason == "ARBITRARY-VALIDATION-SECRET")
        if case let .moveFailed(actualSource, actualDestination, underlyingError) = downloadError {
            #expect(actualSource == source)
            #expect(actualDestination == destination)
            #expect(underlyingError is TestSecretError)
        } else {
            Issue.record("Expected the original move failure case")
        }
    }

    @Test("Every request construction reason has a stable safe description")
    func requestConstructionReasonsUseStableDescriptions() {
        let reasons: [(RequestConstructionError.Reason, String)] = [
            (.relativeRouteRequiresBaseURL, "relative route requires a base URL"),
            (.missingURLScheme, "absolute route has no URL scheme"),
            (.unsupportedURLScheme("https://ROUTE-SECRET"), "absolute route uses an unsupported URL scheme"),
            (.urlCompositionFailed, "URL composition failed"),
            (.urlQueryEncoding(.topLevelContainerUnsupported), "URL query encoding failed"),
            (.queryCompositionFailed, "query composition failed"),
            (.unreadableFileBody, "file-backed request body is unavailable"),
            (.unsupportedOperationBodyCombination, "request body is incompatible with the selected operation"),
        ]

        for (reason, expectedDescription) in reasons {
            let error = RequestConstructionError(requestID: makeRequestID(), reason: reason)
            let description = error.errorDescription ?? ""

            #expect(description.contains(expectedDescription))
            #expect(!description.contains("ROUTE-SECRET"))
        }
    }

    @Test("Foundation error summaries keep domain and code but omit localized text")
    func foundationErrorUsesStructuralIdentity() {
        let error = NSError(
            domain: "ARBITRARY-ERROR-DOMAIN-SECRET",
            code: 27,
            userInfo: [NSLocalizedDescriptionKey: "ARBITRARY-FOUNDATION-SECRET"],
        )
        let event = requestFailedEvent(error: error)
        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("NSError(domain=<redacted>,code=27)"))
        #expect(message.contains("code=27"))
        #expect(!message.contains("ARBITRARY-ERROR-DOMAIN-SECRET"))
        #expect(!message.contains("ARBITRARY-FOUNDATION-SECRET"))
    }

    private func makeRequestID() -> RequestID {
        guard let rawValue = UUID(uuidString: "00000000-0000-0000-0000-000000000021") else {
            Issue.record("The fixed test request identity must be a valid UUID")
            return RequestID(rawValue: UUID())
        }

        return RequestID(rawValue: rawValue)
    }

    private func makeRequest() -> HTTPRequest {
        var headers = HTTPFields()
        guard let apiKeyName = HTTPField.Name("X-Api-Key") else {
            Issue.record("The test API key header name must be valid")
            return HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/")
        }

        headers[.authorization] = "Bearer AUTH-SECRET"
        headers[.cookie] = "session=COOKIE-SECRET"
        headers[apiKeyName] = "API-KEY-SECRET"
        headers[.accept] = "application/json"
        headers[.location] = "https://redirect.example/next?continue=HEADER-QUERY-SECRET"

        return HTTPRequest(
            method: .post,
            scheme: "https",
            authority: "userinfo:password@example.com:8443",
            path: "/v1?token=QUERY-SECRET&empty=&encoded=ENCODED%2BQUERY%2DSECRET&token=SECOND-QUERY-SECRET",
            headerFields: headers,
        )
    }

    private func makeResponse() -> HTTPResponse {
        var headers = HTTPFields()
        headers[.setCookie] = "session=SET-COOKIE-SECRET; Secure"
        headers[.location] = "https://redirect.example/next?continue=HEADER-QUERY-SECRET"
        return HTTPResponse(status: 503, headerFields: headers)
    }

    private func makeValidationError(body: RetainedBody?, reason: String?) -> ResponseValidationError {
        ResponseValidationError(
            httpResponse: makeResponse(),
            retainedBody: body,
            requestID: makeRequestID(),
            attempts: [],
            reason: reason,
        )
    }

    private func requestFailedEvent(error: any Error) -> NetworkEvent {
        .requestFailed(RequestFailedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            error: error,
        ))
    }
}

private struct TestSecretError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "ARBITRARY-ERROR-SECRET"
    }
}

private enum PrivateContextKey: RequestContextKey {
    typealias Value = String
}

private enum TraceContextKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        value
    }
}

private enum SecondTraceContextKey: DiagnosticRequestContextKey {
    typealias Value = String

    static func diagnosticDescription(for value: String) -> String {
        value
    }
}
