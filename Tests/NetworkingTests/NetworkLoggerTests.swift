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

    @Test("Proxy-Authorization credentials are redacted by default")
    func proxyAuthorizationIsMandatorySensitiveByDefault() throws {
        let proxyAuthorizationName = try #require(
            HTTPField.Name("Proxy-Authorization"),
            "The test header names must be valid",
        )
        let extraSecretName = try #require(HTTPField.Name("X-Extra-Secret"), "The test header names must be valid")

        var headers = HTTPFields()
        headers[proxyAuthorizationName] = "Basic PROXY-AUTH-SECRET"
        headers[extraSecretName] = "CALLER-CONFIG-SECRET"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "proxy.example",
            path: "/resource",
            headerFields: headers,
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let defaultMessage = NetworkLoggerFormatter(configuration: .init()).format(event).message
        let configuredMessage = NetworkLoggerFormatter(configuration: .init(
            additionalSensitiveHeaders: ["x-extra-secret"],
        ))
        .format(event)
        .message

        #expect(defaultMessage.contains("proxy-authorization=<redacted>"))
        #expect(!defaultMessage.contains("PROXY-AUTH-SECRET"))
        #expect(configuredMessage.contains("proxy-authorization=<redacted>"))
        #expect(configuredMessage.contains("x-extra-secret=<redacted>"))
        #expect(!configuredMessage.contains("PROXY-AUTH-SECRET"))
        #expect(!configuredMessage.contains("CALLER-CONFIG-SECRET"))
    }

    @Test("Generic header values containing multiple URLs are fully redacted")
    func genericHeaderContainingMultipleURLsIsRedacted() throws {
        let headerName = try #require(
            HTTPField.Name("X-Multi-URL"),
            "The test header name must be valid",
        )
        let linkHeaderName = try #require(HTTPField.Name("Link"), "The Link header name must be valid")
        var headers = HTTPFields()
        headers[headerName] = "https://FIRST-URL-USER:FIRST-URL-PASSWORD@first.example/p, https://SECOND-URL-USER:SECOND-URL-PASSWORD@second.example/next?key=MULTI-URL-QUERY-SECRET"
        headers[linkHeaderName] = "<https://LINK-USER:LINK-PASSWORD@link.example/next?token=LINK-QUERY-SECRET>"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: headers,
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("x-multi-url=<redacted>"))
        #expect(!message.contains("FIRST-URL-USER"))
        #expect(!message.contains("FIRST-URL-PASSWORD"))
        #expect(!message.contains("SECOND-URL-USER"))
        #expect(!message.contains("SECOND-URL-PASSWORD"))
        #expect(!message.contains("MULTI-URL-QUERY-SECRET"))
        #expect(message.contains("link=\"<https://link.example/next?token=<redacted>>\""))
        #expect(!message.contains("LINK-USER"))
        #expect(!message.contains("LINK-PASSWORD"))
        #expect(!message.contains("LINK-QUERY-SECRET"))
    }

    @Test("Scheme-relative references are redacted from generic headers")
    func schemeRelativeGenericHeadersAreRedacted() throws {
        let relativeName = try #require(HTTPField.Name("X-Scheme-Relative"), "The header name must be valid")
        let multiValueName = try #require(HTTPField.Name("X-Unknown-Multi"), "The header name must be valid")
        let pathName = try #require(HTTPField.Name("X-Absolute-Path"), "The header name must be valid")
        let embeddedPathName = try #require(HTTPField.Name("X-Embedded-Path"), "The header name must be valid")
        let parenthesizedPathName = try #require(
            HTTPField.Name("X-Parenthesized-Path"),
            "The header name must be valid",
        )
        let colonPathName = try #require(
            HTTPField.Name("X-Colon-Path"),
            "The header name must be valid",
        )
        let whitespaceURLName = try #require(HTTPField.Name("X-Whitespace-URL"), "The header name must be valid")
        let separatedPathName = try #require(HTTPField.Name("X-Separated-Path"), "The header name must be valid")
        let punctuationPathName = try #require(HTTPField.Name("X-Punctuation-Path"), "The header name must be valid")
        let c1PathName = try #require(HTTPField.Name("X-C1-Path"), "The header name must be valid")
        let formatPathName = try #require(HTTPField.Name("X-Format-Path"), "The header name must be valid")
        let lineSeparatorPathName = try #require(
            HTTPField.Name("X-Line-Separator-Path"),
            "The header name must be valid",
        )
        let formatURLName = try #require(HTTPField.Name("X-Format-URL"), "The header name must be valid")
        let multiSegmentPathName = try #require(HTTPField.Name("X-Multi-Segment-Path"), "The header name must be valid")
        let relativePathName = try #require(HTTPField.Name("X-Relative-Path"), "The header name must be valid")
        let contentTypeName = try #require(HTTPField.Name("Content-Type"), "The header name must be valid")
        let acceptName = try #require(HTTPField.Name("Accept"), "The header name must be valid")
        let plainName = try #require(HTTPField.Name("X-Plain-Value"), "The header name must be valid")
        var headers = HTTPFields()
        headers[relativeName] = "//RELATIVE-USER:RELATIVE-PASSWORD@example.com/path"
        headers[multiValueName] = [
            "rel=next, //MULTI-USER:MULTI-PASSWORD@other.example/path",
            "rel=prev / //SPACED-MULTI-USER:SPACED-MULTI-PASSWORD@third.example/path",
        ].joined(separator: "; ")
        headers[pathName] = "/account/PATH-PRIVATE-ID"
        headers[embeddedPathName] = "rel=next, /account/EMBEDDED-PATH-PRIVATE-ID"
        headers[parenthesizedPathName] = "value(/account/PARENTHESIZED-PATH-PRIVATE-ID)"
        headers[colonPathName] = "value:../COLON-PATH-PRIVATE-ID"
        headers[whitespaceURLName] = "  https://SPACE-USER:SPACE-PASSWORD@example.com/path"
        headers[separatedPathName] = "label\u{00a0}/account/UNICODE-SEPARATOR-PRIVATE-ID"
        headers[punctuationPathName] = "label—/account/UNICODE-PUNCTUATION-PRIVATE-ID"
        headers[c1PathName] = "label\u{0085}/account/C1-SEPARATOR-PRIVATE-ID"
        headers[formatPathName] = "label\u{200b}/account/ZERO-WIDTH-PRIVATE-ID"
        headers[lineSeparatorPathName] = "label\u{2028}/account/LINE-SEPARATOR-PRIVATE-ID"
        headers[formatURLName] = "\u{200b}https://FORMAT-USER:FORMAT-PASSWORD@example.com/path?token=FORMAT-QUERY-SECRET"
        headers[multiSegmentPathName] = "label/account/MULTI-SEGMENT-PRIVATE-ID"
        headers[relativePathName] = "account/SINGLE-SLASH-PRIVATE-ID"
        headers[contentTypeName] = "application/json"
        headers[acceptName] = "application/json, text/plain"
        headers[plainName] = "plain value, still=ordinary / ratio"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: headers,
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("x-scheme-relative=<redacted>"))
        #expect(message.contains("x-unknown-multi=<redacted>"))
        #expect(message.contains("x-absolute-path=<redacted>"))
        #expect(message.contains("x-embedded-path=<redacted>"))
        #expect(message.contains("x-parenthesized-path=<redacted>"))
        #expect(message.contains("x-colon-path=<redacted>"))
        #expect(message.contains("x-whitespace-url=<redacted>"))
        #expect(message.contains("x-separated-path=<redacted>"))
        #expect(message.contains("x-punctuation-path=<redacted>"))
        #expect(message.contains("x-c1-path=<redacted>"))
        #expect(message.contains("x-format-path=<redacted>"))
        #expect(message.contains("x-line-separator-path=<redacted>"))
        #expect(message.contains("x-format-url=<redacted>"))
        #expect(message.contains("x-multi-segment-path=<redacted>"))
        #expect(message.contains("x-relative-path=<redacted>"))
        #expect(message.contains("content-type=application/json"))
        #expect(message.contains("accept=application/json"))
        #expect(!message.contains("RELATIVE-USER"))
        #expect(!message.contains("RELATIVE-PASSWORD"))
        #expect(!message.contains("MULTI-USER"))
        #expect(!message.contains("MULTI-PASSWORD"))
        #expect(!message.contains("SPACED-MULTI-USER"))
        #expect(!message.contains("SPACED-MULTI-PASSWORD"))
        #expect(!message.contains("PATH-PRIVATE-ID"))
        #expect(!message.contains("EMBEDDED-PATH-PRIVATE-ID"))
        #expect(!message.contains("PARENTHESIZED-PATH-PRIVATE-ID"))
        #expect(!message.contains("COLON-PATH-PRIVATE-ID"))
        #expect(!message.contains("SPACE-USER"))
        #expect(!message.contains("SPACE-PASSWORD"))
        #expect(!message.contains("UNICODE-SEPARATOR-PRIVATE-ID"))
        #expect(!message.contains("UNICODE-PUNCTUATION-PRIVATE-ID"))
        #expect(!message.contains("C1-SEPARATOR-PRIVATE-ID"))
        #expect(!message.contains("ZERO-WIDTH-PRIVATE-ID"))
        #expect(!message.contains("LINE-SEPARATOR-PRIVATE-ID"))
        #expect(!message.contains("FORMAT-USER"))
        #expect(!message.contains("FORMAT-PASSWORD"))
        #expect(!message.contains("FORMAT-QUERY-SECRET"))
        #expect(!message.contains("MULTI-SEGMENT-PRIVATE-ID"))
        #expect(!message.contains("SINGLE-SLASH-PRIVATE-ID"))
        #expect(message.contains(#"x-plain-value=plain\svalue\,\sstill\=ordinary\s/\sratio"#))
    }

    @Test("Accept and Content-Type redact explicit URL references")
    func mediaTypeHeadersRedactExplicitURLReferences() throws {
        let acceptName = try #require(HTTPField.Name("Accept"), "The header name must be valid")
        let contentTypeName = try #require(HTTPField.Name("Content-Type"), "The header name must be valid")
        var headers = HTTPFields()
        headers[acceptName] = "application/json, https://ACCEPT-USER:ACCEPT-PASSWORD@example.com/path?token=ACCEPT-QUERY-SECRET"
        headers[contentTypeName] = "https://CONTENT-USER:CONTENT-PASSWORD@example.com/path?token=CONTENT-QUERY-SECRET"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: headers,
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("accept=<redacted>"))
        #expect(message.contains("content-type=<redacted>"))
        #expect(!message.contains("ACCEPT-USER"))
        #expect(!message.contains("ACCEPT-PASSWORD"))
        #expect(!message.contains("ACCEPT-QUERY-SECRET"))
        #expect(!message.contains("CONTENT-USER"))
        #expect(!message.contains("CONTENT-PASSWORD"))
        #expect(!message.contains("CONTENT-QUERY-SECRET"))
    }

    @Test("Media-type parameters redact path references")
    func mediaTypeParametersRedactPathReferences() throws {
        let acceptName = try #require(HTTPField.Name("Accept"), "The header name must be valid")
        let contentTypeName = try #require(HTTPField.Name("Content-Type"), "The header name must be valid")
        var headers = HTTPFields()
        headers[acceptName] = "application/json, text/plain; profile=account/ACCEPT-PATH-PRIVATE-ID"
        headers[contentTypeName] = "application/json; profile=/account/CONTENT-PATH-PRIVATE-ID"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: headers,
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("accept=<redacted>"))
        #expect(message.contains("content-type=<redacted>"))
        #expect(!message.contains("ACCEPT-PATH-PRIVATE-ID"))
        #expect(!message.contains("CONTENT-PATH-PRIVATE-ID"))
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

    @Test("Unicode controls and separators are escaped across diagnostic surfaces")
    func unicodeControlsAndSeparatorsAreEscaped() throws {
        let unicodeText = "café\u{00a0} 🦄\u{2028}\u{2029}\u{202e}"
        let escapedUnicodeText = #"café\u{A0}\s🦄\u{2028}\u{2029}\u{202E}"#
        let headerText = unicodeText + "\u{0085}\u{200b}"
        let escapedHeaderText = escapedUnicodeText + #"\u{85}\u{200B}"#
        let bodyText = unicodeText + "\t\n\r"
        let escapedBodyText = escapedUnicodeText + "\\t\\n\\r"
        let contextValue = "\u{0001}" + bodyText
        let escapedContextValue = "\\u{1}" + escapedBodyText

        let bodyBytes = Data(bodyText.utf8)
        let error = makeValidationError(
            body: RetainedBody(data: bodyBytes, originalByteCount: Int64(bodyBytes.count)),
            reason: nil,
        )
        let bodyFormatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: UInt(bodyBytes.count)),
        ))
        let bodyMessage = bodyFormatter.format(requestFailedEvent(error: error)).message

        let descriptionName = try #require(HTTPField.Name("X-Description"), "The header name must be valid")
        let locationName = try #require(HTTPField.Name("Location"), "The header name must be valid")
        var headers = HTTPFields()
        headers[descriptionName] = headerText
        headers[locationName] = "https://example.com/path\u{2028}segment"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: headers,
        )
        let context = RequestContext().setting(TraceContextKey.self, value: contextValue)
        let contextEvent = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: context,
            attemptNumber: 1,
            request: request,
        ))
        let diagnosticMessage = NetworkLoggerFormatter(configuration: .init()).format(contextEvent).message

        #expect(bodyMessage.contains("body=text"))
        #expect(bodyMessage.contains("content=\(escapedBodyText)"))
        #expect(diagnosticMessage.contains("x-description=\(escapedHeaderText)"))
        #expect(diagnosticMessage.contains(escapedContextValue))
        #expect(diagnosticMessage.contains(#"café\u{A0}\s🦄"#))
        #expect(diagnosticMessage.contains(#"location="https://example.com/path%E2%80%A8segment""#))
        #expect(!bodyMessage.contains("\u{2028}"))
        #expect(!bodyMessage.contains("\u{2029}"))
        #expect(!bodyMessage.contains("\u{202e}"))
        #expect(!bodyMessage.contains("\u{00a0}"))
        #expect(!diagnosticMessage.contains("\u{0001}"))
        #expect(!diagnosticMessage.contains("\u{2028}"))
        #expect(!diagnosticMessage.contains("\u{2029}"))
        #expect(!diagnosticMessage.contains("\u{202e}"))
        #expect(!diagnosticMessage.contains("\u{00a0}"))
        #expect(!diagnosticMessage.contains("\u{0085}"))
        #expect(!diagnosticMessage.contains("\u{200b}"))
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
        let original = Data("A🦄".utf8)
        let error = makeValidationError(
            body: RetainedBody(data: original, originalByteCount: Int64(original.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 2),
        ))
        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("content=A"))
        #expect(message.contains("emitted_bytes=1"))
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

    @Test("C0, DEL, and C1 control bytes are described structurally")
    func controlBytesAreDescribedStructurally() {
        let cases = [
            Data([0x00, 0x01, 0x02]),
            Data([0x1b, 0x7f]),
            Data([0xc2, 0x80]),
        ]

        for bytes in cases {
            let error = makeValidationError(
                body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
                reason: nil,
            )
            let formatter = NetworkLoggerFormatter(configuration: .init(
                bodyDiagnostics: .enabled(maximumBytes: UInt(bytes.count)),
            ))
            let message = formatter.format(requestFailedEvent(error: error)).message

            #expect(message.contains("body=binary"))
            #expect(!message.contains("body=text"))
            #expect(!message.contains("content="))
        }
    }

    @Test("Tab, newline, and carriage return remain escaped text")
    func permittedWhitespaceControlsRemainText() {
        let bytes = Data([0x09, 0x0a, 0x0d])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: UInt(bytes.count)),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("content=\\t\\n\\r"))
        #expect(!message.contains("body=binary"))
    }

    @Test("Ordinary Unicode body text remains textual")
    func ordinaryUnicodeBodyRemainsText() {
        let bodyText = "café 🦄"
        let bytes = Data(bodyText.utf8)
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: UInt(bytes.count)),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("content=café\\s🦄"))
        #expect(!message.contains("body=binary"))
    }

    @Test("A small body cap classifies only its bounded prefix")
    func largeRetainedBodyUsesOnlyTheConfiguredPrefix() {
        var bytes = Data("bounded".utf8)
        bytes.append(contentsOf: repeatElement(UInt8(0xff), count: 2_000_000))
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 7),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("content=bounded"))
        #expect(message.contains("emitted_bytes=7"))
        #expect(message.contains("retained_bytes=2000007"))
        #expect(message.contains("truncated=true"))
    }

    @Test("Invalid UTF-8 inside the bounded prefix remains structural")
    func invalidUTF8WithinCappedPrefixRemainsBinary() {
        let bytes = Data([0x41, 0xff, 0x42])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 3),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=binary"))
        #expect(!message.contains("body=text"))
        #expect(!message.contains("content=A"))
        #expect(!message.contains("content=B"))
    }

    @Test("An incomplete UTF-8 scalar at the cap remains structural")
    func incompleteUTF8AtCapRemainsBinary() {
        let bytes = Data([0x41, 0xf0, 0x90])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 2),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=binary"))
        #expect(!message.contains("body=text"))
        #expect(!message.contains("content=A"))
    }

    @Test("A truncated retained body preserves text before an incomplete scalar")
    func truncatedRetainedBodyKeepsValidTextPrefix() {
        let bytes = Data([0x41, 0xf0, 0x90])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: 5),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 2),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=text"))
        #expect(message.contains("content=A"))
        #expect(message.contains("emitted_bytes=1"))
        #expect(message.contains("truncated=true"))
        #expect(!message.contains("body=binary"))
    }

    @Test("A zero-byte body cap emits metadata without classifying content")
    func zeroByteBodyCapEmitsMetadataOnly() {
        let bytes = Data([0xff, 0x00, 0x41])
        let error = makeValidationError(
            body: RetainedBody(data: bytes, originalByteCount: Int64(bytes.count)),
            reason: nil,
        )
        let formatter = NetworkLoggerFormatter(configuration: .init(
            bodyDiagnostics: .enabled(maximumBytes: 0),
        ))

        let message = formatter.format(requestFailedEvent(error: error)).message

        #expect(message.contains("body=omitted"))
        #expect(message.contains("retained_bytes=3"))
        #expect(message.contains("original_bytes=3"))
        #expect(message.contains("emitted_bytes=0"))
        #expect(message.contains("truncated=true"))
        #expect(!message.contains("body=text"))
        #expect(!message.contains("body=binary"))
        #expect(!message.contains("content="))
    }

    @Test("Unknown errors use structural identity instead of their free-form description")
    func unknownErrorDescriptionIsNotLogged() {
        let event = requestFailedEvent(error: TestSecretError())
        let diagnostic = NetworkLoggerFormatter(configuration: .init()).format(event)

        #expect(diagnostic.message.contains("TestSecretError"))
        #expect(!diagnostic.message.contains("ARBITRARY-ERROR-SECRET"))
        #expect(diagnostic.level == .error)
    }

    @Test("Structural error identities do not use custom error descriptions")
    func structuralErrorIdentityIgnoresCustomDescription() {
        struct CustomDescriptionError: Error, CustomStringConvertible {
            var description: String {
                "CUSTOM-ERROR-DESCRIPTION-SECRET"
            }
        }

        let message = NetworkLoggerFormatter(configuration: .init())
            .format(requestFailedEvent(error: CustomDescriptionError()))
            .message

        #expect(message.contains("CustomDescriptionError"))
        #expect(!message.contains("CUSTOM-ERROR-DESCRIPTION-SECRET"))
    }

    @Test("Function-local error identities omit runtime addresses")
    func functionLocalErrorIdentityIsStableAndAddressFree() {
        struct FunctionLocalDiagnosticError: Error {}

        let event = requestFailedEvent(error: FunctionLocalDiagnosticError())
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let firstMessage = formatter.format(event).message
        let secondMessage = formatter.format(event).message

        #expect(firstMessage == secondMessage)
        #expect(firstMessage.contains("FunctionLocalDiagnosticError"))
        #expect(!firstMessage.contains("NetworkLoggerTests."))
        #expect(firstMessage.contains("domain=<redacted>"))
        #expect(firstMessage.contains("code="))
        #expect(!firstMessage.contains("unknown context at $"))
        #expect(!firstMessage.contains("context at"))
        #expect(!firstMessage.contains("$"))
        #expect(!firstMessage.contains("0x"))
    }

    @Test("Function-local generic error identities remain stable and address-free")
    func functionLocalGenericErrorIdentityIsStableAndAddressFree() {
        struct FunctionLocalGenericDiagnosticError<Context>: Error {}
        enum TypeNamespace {
            struct Detail {}
        }

        let error = FunctionLocalGenericDiagnosticError<TypeNamespace.Detail>()
        let event = requestFailedEvent(error: error)
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let firstMessage = formatter.format(event).message
        let secondMessage = formatter.format(event).message

        #expect(firstMessage == secondMessage)
        #expect(firstMessage.contains("FunctionLocalGenericDiagnosticError"))
        #expect(!firstMessage.contains("TypeNamespace.Detail"))
        #expect(!firstMessage.contains("unknown context at $"))
        #expect(!firstMessage.contains("$"))
        #expect(!firstMessage.contains("0x"))
    }

    @Test("Generic error identities retain the outer nominal type")
    func genericErrorIdentityOmitsTypeArguments() {
        struct GenericDiagnosticError<Context>: Error {}
        enum TypeNamespace {
            struct Detail {}
        }

        let error = GenericDiagnosticError<TypeNamespace.Detail>()
        let reflectedTypeName = String(reflecting: Swift.type(of: error))
        let message = NetworkLoggerFormatter(configuration: .init())
            .format(requestFailedEvent(error: error))
            .message

        #expect(reflectedTypeName.contains("TypeNamespace.Detail"))
        #expect(message.contains("error=GenericDiagnosticError(domain=<redacted>,code="))
        #expect(!message.contains("TypeNamespace.Detail"))
        #expect(!message.contains("NetworkingTests."))
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
