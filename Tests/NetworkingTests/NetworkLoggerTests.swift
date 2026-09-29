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

    @Test("Request URL query names cannot expose embedded URL credentials")
    func requestURLQueryNamesCannotExposeEmbeddedURLCredentials() {
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource?next,https://REQUEST-URL-USER:REQUEST-URL-PASSWORD@private.example/path?token=REQUEST-URL-QUERY-SECRET",
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("<redacted>=<redacted>"))
        #expect(!message.contains("REQUEST-URL-USER"))
        #expect(!message.contains("REQUEST-URL-PASSWORD"))
        #expect(!message.contains("REQUEST-URL-QUERY-SECRET"))
    }

    @Test("Percent-encoded URL references in query names are redacted everywhere")
    func percentEncodedURLReferencesInQueryNamesAreRedactedEverywhere() throws {
        let requestName = [
            "https%3A%2F%2FREQUEST-NAME-USER%3A",
            "REQUEST-NAME-PASSWORD%40private.example%2Fpath%3Ftoken%3D",
            "REQUEST-NESTED-QUERY-SECRET",
        ].joined()
        let doubleEncodedRequestName = [
            "https%253A%252F%252FDOUBLE-ENCODED-USER%253A",
            "DOUBLE-ENCODED-PASSWORD%2540private.example%252Fpath%253Ftoken%253D",
            "DOUBLE-ENCODED-NESTED-QUERY-SECRET",
        ].joined()
        let headerQueryName = [
            "https%3A%2F%2FHEADER-NAME-USER%3A",
            "HEADER-NAME-PASSWORD%40private.example%2Fpath%3Ftoken%3D",
            "HEADER-NESTED-QUERY-SECRET",
        ].joined()
        let linkQueryName = [
            "https%3A%2F%2FLINK-NAME-USER%3A",
            "LINK-NAME-PASSWORD%40private.example%2Fpath%3Ftoken%3D",
            "LINK-NESTED-QUERY-SECRET",
        ].joined()
        let locationName = try #require(HTTPField.Name("Location"), "The Location header name must be valid")
        let linkName = try #require(HTTPField.Name("Link"), "The Link header name must be valid")
        var headers = HTTPFields()
        headers[locationName] = "https://redirect.example/next?\(headerQueryName)=header-value"
        headers[linkName] = "<https://link.example/next?\(linkQueryName)=link-value>; rel=next"
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource?\(requestName)=request-value&\(doubleEncodedRequestName)=double-encoded-request-value",
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

        #expect(message.contains("<redacted>=<redacted>"))
        #expect(message.contains(#"location="<redacted>""#))
        #expect(message.contains(#"link="<redacted>""#))
        for secret in [
            "REQUEST-NAME-USER",
            "REQUEST-NAME-PASSWORD",
            "REQUEST-NESTED-QUERY-SECRET",
            "DOUBLE-ENCODED-USER",
            "DOUBLE-ENCODED-PASSWORD",
            "DOUBLE-ENCODED-NESTED-QUERY-SECRET",
            "HEADER-NAME-USER",
            "HEADER-NAME-PASSWORD",
            "HEADER-NESTED-QUERY-SECRET",
            "LINK-NAME-USER",
            "LINK-NAME-PASSWORD",
            "LINK-NESTED-QUERY-SECRET",
        ] {
            #expect(!message.contains(secret))
        }
    }

    @Test("Malformed percent encoding in a request query name is redacted")
    func malformedPercentEncodingInQueryNameIsRedacted() {
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource?bad%ZZ-name=MALFORMED-QUERY-NAME-SECRET",
        )
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("<url-unavailable>"))
        #expect(!message.contains("bad%ZZ-name"))
        #expect(!message.contains("MALFORMED-QUERY-NAME-SECRET"))
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

    @Test("Authentication-Info headers are mandatory-sensitive under all configurations")
    func authenticationInfoHeadersAreMandatorySensitiveByDefault() throws {
        let authenticationInfoName = try #require(
            HTTPField.Name("Authentication-Info"),
            "The Authentication-Info header name must be valid",
        )
        let proxyAuthenticationInfoName = try #require(
            HTTPField.Name("Proxy-Authentication-Info"),
            "The Proxy-Authentication-Info header name must be valid",
        )
        let additionalSecretName = try #require(
            HTTPField.Name("X-Additional-Secret"),
            "The additional test header name must be valid",
        )
        var headers = HTTPFields()
        headers[authenticationInfoName] = "nextnonce=AUTHENTICATION-INFO-SECRET"
        headers[proxyAuthenticationInfoName] = "nextnonce=PROXY-AUTHENTICATION-INFO-SECRET"
        headers[additionalSecretName] = "ADDITIONAL-CONFIGURED-SECRET"
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
        let defaultMessage = NetworkLoggerFormatter(configuration: .init()).format(event).message
        let configuredMessage = NetworkLoggerFormatter(configuration: .init(
            additionalSensitiveHeaders: ["x-additional-secret"],
        ))
        .format(event)
        .message

        for message in [defaultMessage, configuredMessage] {
            #expect(message.contains("authentication-info=<redacted>"))
            #expect(message.contains("proxy-authentication-info=<redacted>"))
            #expect(!message.contains("AUTHENTICATION-INFO-SECRET"))
            #expect(!message.contains("PROXY-AUTHENTICATION-INFO-SECRET"))
        }
        #expect(configuredMessage.contains("x-additional-secret=<redacted>"))
        #expect(!configuredMessage.contains("ADDITIONAL-CONFIGURED-SECRET"))
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

    @Test("A Link target containing a second URL is redacted as a whole")
    func ambiguousLinkTargetIsRedacted() throws {
        let message = try messageForRequestHeader(
            "Link",
            value: "<https://first.example/path,https://SECOND:PASSWORD@second.example/next>",
        )

        #expect(message.contains(#"link="<redacted>""#))
        #expect(!message.contains("SECOND"))
        #expect(!message.contains("PASSWORD"))
    }

    @Test("Safe Link targets remain useful beside an ambiguous target")
    func safeAndAmbiguousLinkTargetsAreRenderedIndependently() throws {
        let message = try messageForRequestHeader(
            "Link",
            value: "<https://safe.example/alternate?token=SAFE-LINK-QUERY-SECRET>; rel=alternate, "
                +
                "<https://first.example/path,https://SECOND:PASSWORD@second.example/next?token=AMBIGUOUS-LINK-QUERY-SECRET>; rel=next",
        )

        #expect(message.contains(#"<https://safe.example/alternate?token=<redacted>>"#))
        #expect(message.contains("<redacted>"))
        #expect(!message.contains("SECOND"))
        #expect(!message.contains("PASSWORD"))
        #expect(!message.contains("SAFE-LINK-QUERY-SECRET"))
        #expect(!message.contains("AMBIGUOUS-LINK-QUERY-SECRET"))
    }

    @Test("Multiple valid Link entries retain sanitized URL shapes")
    func multipleValidLinkTargetsRemainUseful() throws {
        let message = try messageForRequestHeader(
            "Link",
            value: "<https://one.example/next?token=FIRST-LINK-QUERY-SECRET>; rel=next, "
                + "<https://two.example/alternate>; rel=alternate",
        )

        #expect(message.contains(#"<https://one.example/next?token=<redacted>>"#))
        #expect(message.contains("<https://two.example/alternate>"))
        #expect(!message.contains("FIRST-LINK-QUERY-SECRET"))
    }

    @Test("Ambiguous dedicated URL headers are redacted as whole values")
    func ambiguousDedicatedURLHeadersAreFullyRedacted() throws {
        let locationName = try #require(HTTPField.Name("Location"), "The Location header name must be valid")
        let contentLocationName = try #require(
            HTTPField.Name("Content-Location"),
            "The Content-Location header name must be valid",
        )
        let refererName = try #require(HTTPField.Name("Referer"), "The Referer header name must be valid")
        var headers = HTTPFields()
        headers[locationName] = "https://first.example/path, //LOCATION-USER:LOCATION-PASSWORD@second.example/path?token=LOCATION-QUERY-SECRET"
        headers[contentLocationName] = "https://first.example/path?next,https://CONTENT-USER:CONTENT-PASSWORD@second.example/path?token=CONTENT-QUERY-SECRET"
        headers[refererName] = "https://first.example/path, https://REFERER-USER:REFERER-PASSWORD@second.example/path?token=REFERER-QUERY-SECRET"
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

        #expect(message.contains("location=\"<redacted>\""))
        #expect(message.contains("content-location=\"<redacted>\""))
        #expect(message.contains("referer=\"<redacted>\""))
        for secret in [
            "LOCATION-USER",
            "LOCATION-PASSWORD",
            "LOCATION-QUERY-SECRET",
            "CONTENT-USER",
            "CONTENT-PASSWORD",
            "CONTENT-QUERY-SECRET",
            "REFERER-USER",
            "REFERER-PASSWORD",
            "REFERER-QUERY-SECRET",
        ] {
            #expect(!message.contains(secret))
        }

        var ordinaryHeaders = HTTPFields()
        ordinaryHeaders[locationName] = "https://example.com/path//segment"
        let ordinaryRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: ordinaryHeaders,
        )
        let ordinaryEvent = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: ordinaryRequest,
        ))
        let ordinaryMessage = NetworkLoggerFormatter(configuration: .init()).format(ordinaryEvent).message

        #expect(ordinaryMessage.contains("location=\"https://example.com/path//segment\""))

        var credentialHeaders = HTTPFields()
        credentialHeaders[locationName] = "https://LOCATION-USER:LOCATION-PASSWORD@example.com/path?token=LOCATION-QUERY-SECRET"
        let credentialRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: credentialHeaders,
        )
        let credentialEvent = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: credentialRequest,
        ))
        let credentialMessage = NetworkLoggerFormatter(configuration: .init()).format(credentialEvent).message

        #expect(credentialMessage.contains("location=\"https://example.com/path?token=<redacted>\""))
        #expect(!credentialMessage.contains("LOCATION-USER"))
        #expect(!credentialMessage.contains("LOCATION-PASSWORD"))
        #expect(!credentialMessage.contains("LOCATION-QUERY-SECRET"))

        var nestedQueryHeaders = HTTPFields()
        nestedQueryHeaders[locationName] = "https://safe.example/path?next=https://NESTED-URL-USER:NESTED-URL-PASSWORD@private.example/path?secret=NESTED-URL-QUERY-SECRET"
        let nestedQueryRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/resource",
            headerFields: nestedQueryHeaders,
        )
        let nestedQueryEvent = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: nestedQueryRequest,
        ))
        let nestedQueryMessage = NetworkLoggerFormatter(configuration: .init()).format(nestedQueryEvent).message

        #expect(nestedQueryMessage.contains("location=\"https://safe.example/path?next=<redacted>\""))
        #expect(!nestedQueryMessage.contains("NESTED-URL-USER"))
        #expect(!nestedQueryMessage.contains("NESTED-URL-PASSWORD"))
        #expect(!nestedQueryMessage.contains("NESTED-URL-QUERY-SECRET"))
    }

    @Test("Scheme-relative references are redacted from generic headers")
    func schemeRelativeGenericHeadersAreRedacted() throws {
        let relativeName = try #require(HTTPField.Name("X-Scheme-Relative"), "The header name must be valid")
        let multiValueName = try #require(HTTPField.Name("X-Unknown-Multi"), "The header name must be valid")
        let absoluteURLName = try #require(HTTPField.Name("X-Absolute-URL"), "The header name must be valid")
        let queryName = try #require(HTTPField.Name("X-Query"), "The header name must be valid")
        var headers = HTTPFields()
        headers[relativeName] = "//RELATIVE-USER:RELATIVE-PASSWORD@example.com/path"
        headers[multiValueName] = [
            "rel=next, //FIRST-USER:FIRST-PASSWORD@first.example/path",
            "rel=prev / //SECOND-USER:SECOND-PASSWORD@second.example/path",
        ].joined(separator: "; ")
        headers[absoluteURLName] = "https://ABSOLUTE-USER:ABSOLUTE-PASSWORD@example.com/path?token=ABSOLUTE-QUERY-SECRET"
        headers[queryName] = "search?token=GENERIC-QUERY-SECRET"
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
        #expect(message.contains("x-absolute-url=<redacted>"))
        #expect(message.contains("x-query=<redacted>"))
        #expect(!message.contains("RELATIVE-USER"))
        #expect(!message.contains("RELATIVE-PASSWORD"))
        #expect(!message.contains("FIRST-USER"))
        #expect(!message.contains("FIRST-PASSWORD"))
        #expect(!message.contains("SECOND-USER"))
        #expect(!message.contains("SECOND-PASSWORD"))
        #expect(!message.contains("ABSOLUTE-USER"))
        #expect(!message.contains("ABSOLUTE-PASSWORD"))
        #expect(!message.contains("ABSOLUTE-QUERY-SECRET"))
        #expect(!message.contains("GENERIC-QUERY-SECRET"))
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

    @Test("Ordinary slash-containing header values remain visible")
    func ordinarySlashContainingHeadersRemainVisible() throws {
        let userAgentName = try #require(HTTPField.Name("User-Agent"), "The header name must be valid")
        let acceptName = try #require(HTTPField.Name("Accept"), "The header name must be valid")
        let contentTypeName = try #require(HTTPField.Name("Content-Type"), "The header name must be valid")
        let pathName = try #require(HTTPField.Name("X-Single-Slash-Path"), "The header name must be valid")
        let tokenName = try #require(HTTPField.Name("X-Slash-Token"), "The header name must be valid")
        var headers = HTTPFields()
        headers[userAgentName] = "MyApp/1.0"
        headers[acceptName] = "application/json, text/plain"
        headers[contentTypeName] = "application/json; charset=utf-8"
        headers[pathName] = "/account/v1"
        headers[tokenName] = "token/value"
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

        #expect(message.contains("user-agent=MyApp/1.0"))
        #expect(message.contains(#"accept=application/json\,\stext/plain"#))
        #expect(message.contains(#"content-type=application/json;\scharset\=utf-8"#))
        #expect(message.contains("x-single-slash-path=/account/v1"))
        #expect(message.contains("x-slash-token=token/value"))
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

    @Test("Formatting an arbitrary LocalizedError does not read description metadata")
    func arbitraryLocalizedErrorMetadataIsNotEvaluatedForDiagnostics() {
        let recorder = LocalizedErrorDescriptionRecorder()
        let error = RecordedLocalizedError(recorder: recorder)

        let message = NetworkLoggerFormatter(configuration: .init())
            .format(requestFailedEvent(error: error))
            .message

        #expect(message.contains("RecordedLocalizedError"))
        #expect(recorder.invocationCount == 0)
        #expect(!message.contains("LOCALIZED-DESCRIPTION-SECRET"))
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
        #expect(!firstMessage.contains("domain="))
        #expect(!firstMessage.contains(",code="))
        #expect(!firstMessage.contains("unknown context at $"))
        #expect(!firstMessage.contains("context at"))
        #expect(!firstMessage.contains("$"))
        #expect(!firstMessage.contains("0x"))
    }

    @Test("Nested diagnostic keys under one generic type retain distinct names and values")
    func nestedGenericDiagnosticContextKeysRemainDistinct() {
        struct NestedGenericArgument {}
        typealias Container = GenericDiagnosticContainer<DiagnosticArgumentBox<NestedGenericArgument>>
        let context = RequestContext()
            .setting(Container.FirstKey.self, value: "SAFE-FIRST-NESTED-VALUE")
            .setting(Container.SecondKey.self, value: "SAFE-SECOND-NESTED-VALUE")
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource")
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: context,
            attemptNumber: 1,
            request: request,
        ))

        let message = NetworkLoggerFormatter(configuration: .init()).format(event).message

        #expect(message.contains("GenericDiagnosticContainer<"))
        #expect(message.contains(">.FirstKey"))
        #expect(message.contains(">.SecondKey"))
        #expect(message.contains(#"first\=SAFE-FIRST-NESTED-VALUE"#))
        #expect(message.contains(#"second\=SAFE-SECOND-NESTED-VALUE"#))
        #expect(message.contains("DiagnosticArgumentBox"))
        #expect(message.contains("NestedGenericArgument"))
        #expect(!message.contains("unknown context at $"))
        #expect(!message.contains("$"))
        #expect(!message.contains("0x"))
    }

    @Test("Function arrows inside generic arguments preserve nested type names")
    func functionTypeGenericArgumentPreservesNestedTypeName() {
        typealias Container = GenericDiagnosticContainer<() -> String>

        let name = NetworkDiagnosticTypeName.stableName(
            for: Container.FirstKey.self,
            includingNamespace: true,
        )

        #expect(name.hasSuffix("GenericDiagnosticContainer.FirstKey"))
        #expect(!name.contains("String"))
    }

    @Test("Function-local diagnostic context key names remain distinct and address-free")
    func functionLocalDiagnosticContextKeyNamesRemainDistinctAndAddressFree() {
        enum FirstNamespace {
            enum SharedDiagnosticKey: DiagnosticRequestContextKey {
                typealias Value = String

                static func diagnosticDescription(for value: String) -> String {
                    "first=\(value)"
                }
            }
        }
        enum SecondNamespace {
            enum SharedDiagnosticKey: DiagnosticRequestContextKey {
                typealias Value = String

                static func diagnosticDescription(for value: String) -> String {
                    "second=\(value)"
                }
            }
        }

        let context = RequestContext()
            .setting(FirstNamespace.SharedDiagnosticKey.self, value: "SAFE-FIRST-CONTEXT")
            .setting(SecondNamespace.SharedDiagnosticKey.self, value: "SAFE-SECOND-CONTEXT")
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/resource")
        let event = NetworkEvent.attemptStarted(AttemptStartedEvent(
            requestID: makeRequestID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            requestContext: context,
            attemptNumber: 1,
            request: request,
        ))
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let firstMessage = formatter.format(event).message
        let secondMessage = formatter.format(event).message

        #expect(firstMessage == secondMessage)
        #expect(firstMessage.contains("FirstNamespace.SharedDiagnosticKey"))
        #expect(firstMessage.contains("SecondNamespace.SharedDiagnosticKey"))
        #expect(firstMessage.contains(#"first\=SAFE-FIRST-CONTEXT"#))
        #expect(firstMessage.contains(#"second\=SAFE-SECOND-CONTEXT"#))
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
        #expect(message.contains("error=GenericDiagnosticError"))
        #expect(!message.contains("GenericDiagnosticError(domain="))
        #expect(!message.contains("GenericDiagnosticError(domain=<redacted>,code="))
        #expect(!message.contains("TypeNamespace.Detail"))
        #expect(!message.contains("NetworkingTests."))
    }

    @Test("A nested error reports its own name without generic arguments")
    func nestedGenericErrorIdentityUsesNestedTypeName() {
        struct NestedGenericArgument {}
        typealias Container = GenericDiagnosticContainer<DiagnosticArgumentBox<NestedGenericArgument>>
        let error = Container.NestedDiagnosticError()
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let firstMessage = formatter.format(requestFailedEvent(error: error)).message
        let secondMessage = formatter.format(requestFailedEvent(error: error)).message

        #expect(firstMessage.contains("error=NestedDiagnosticError"))
        #expect(firstMessage == secondMessage)
        #expect(!firstMessage.contains("GenericDiagnosticContainer"))
        #expect(!firstMessage.contains("DiagnosticArgumentBox"))
        #expect(!firstMessage.contains("NestedGenericArgument"))
        #expect(!firstMessage.contains("unknown context at $"))
        #expect(!firstMessage.contains("$"))
        #expect(!firstMessage.contains("0x"))
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

    @Test("CustomNSError codes are retained without reading user info")
    func customNSErrorUsesStructuralCodeWithoutReadingUserInfo() {
        let recorder = LocalizedErrorDescriptionRecorder()
        let error = RecordedCustomNSError(code: 42, recorder: recorder)

        let message = NetworkLoggerFormatter(configuration: .init())
            .format(requestFailedEvent(error: error))
            .message

        #expect(message.contains("RecordedCustomNSError(domain=<redacted>,code=42)"))
        #expect(recorder.invocationCount == 0)
        #expect(!message.contains("CUSTOM-ERROR-USERINFO-SECRET"))
        #expect(!message.contains("CUSTOM-ERROR-DOMAIN-SECRET"))
    }

    @Test("Embedded URLs in request paths are redacted for attempts and redirects")
    func requestEmbeddedURLsAreRedacted() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let requestID = makeRequestID()
        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "safe.example",
            path: "/path,https://REQUEST-USER:REQUEST-PASSWORD@private.example/next",
            headerFields: HTTPFields(),
        )
        let redirectRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "safe.example",
            path: "/path,//REDIRECT-USER:REDIRECT-PASSWORD@private.example/next",
            headerFields: HTTPFields(),
        )
        let formatter = NetworkLoggerFormatter(configuration: .init())
        let attempt = formatter.format(.attemptStarted(AttemptStartedEvent(
            requestID: requestID,
            timestamp: timestamp,
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: request,
        )))
        let redirect = formatter.format(.redirectDecision(RedirectDecisionEvent(
            requestID: requestID,
            timestamp: timestamp,
            requestContext: RequestContext(),
            attemptNumber: 1,
            redirectOrdinal: 1,
            httpResponse: makeResponse(),
            proposedRequest: redirectRequest,
            decision: .reject,
        )))

        #expect(attempt.message.contains("url=<redacted>"))
        #expect(!attempt.message.contains("REQUEST-USER"))
        #expect(!attempt.message.contains("REQUEST-PASSWORD"))
        #expect(redirect.message.contains("url=<redacted>"))
        #expect(!redirect.message.contains("REDIRECT-USER"))
        #expect(!redirect.message.contains("REDIRECT-PASSWORD"))

        let ordinaryRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "safe.example",
            path: "/api//v1?token=REPEATED-SLASH-QUERY-SECRET",
            headerFields: HTTPFields(),
        )
        let ordinary = formatter.format(.attemptStarted(AttemptStartedEvent(
            requestID: requestID,
            timestamp: timestamp,
            requestContext: RequestContext(),
            attemptNumber: 1,
            request: ordinaryRequest,
        )))
        #expect(ordinary.message.contains("url=https://safe.example/api//v1?token=<redacted>"))
        #expect(!ordinary.message.contains("REPEATED-SLASH-QUERY-SECRET"))
    }

    @Test("Percent-encoded URL references in generic headers are redacted")
    func genericHeaderEncodedURLsAreRedacted() throws {
        let singleName = try #require(HTTPField.Name("X-Encoded-Single"), "The test header name must be valid")
        let doubleName = try #require(HTTPField.Name("X-Encoded-Double"), "The test header name must be valid")
        let finalLayerName = try #require(
            HTTPField.Name("X-Encoded-Final-Layer"),
            "The test header name must be valid",
        )
        let deepName = try #require(HTTPField.Name("X-Encoded-Deep"), "The test header name must be valid")
        let malformedName = try #require(HTTPField.Name("X-Encoded-Malformed"), "The test header name must be valid")
        let ordinaryName = try #require(HTTPField.Name("X-Percent-Text"), "The test header name must be valid")
        var headers = HTTPFields()
        headers[singleName] =
            "https%3A%2F%2FHEADER-USER:HEADER-PASSWORD@private.example/path%3F" +
            "token%3DSINGLE-HEADER-QUERY-SECRET"
        headers[doubleName] =
            "https%253A%252F%252FDOUBLE-USER:DOUBLE-PASSWORD@private.example/path%253F" +
            "token%253DDOUBLE-HEADER-QUERY-SECRET"
        var encodedQueryMarker = "%3F"
        var finalLayerQueryMarker = encodedQueryMarker
        var deeplyEncodedQueryMarker = encodedQueryMarker
        for layer in 2 ... 9 {
            encodedQueryMarker = encodedQueryMarker.replacing("%", with: "%25")
            if layer == 8 {
                finalLayerQueryMarker = encodedQueryMarker
            } else if layer == 9 {
                deeplyEncodedQueryMarker = encodedQueryMarker
            }
        }
        #expect(finalLayerQueryMarker == "%252525252525253F")
        #expect(deeplyEncodedQueryMarker == "%25252525252525253F")
        headers[finalLayerName] = "opaque\(finalLayerQueryMarker)token=FINAL-LAYER-QUERY-SECRET"
        headers[deepName] = "opaque\(deeplyEncodedQueryMarker)token=DEEP-HEADER-QUERY-SECRET"
        headers[malformedName] = "https%3A%2F%2FMALFORMED-USER:MALFORMED-PASSWORD@private.example/path%ZZ"
        headers[ordinaryName] = "release%2Fbeta"

        let request = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "safe.example",
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

        #expect(message.contains("x-encoded-single=<redacted>"))
        #expect(message.contains("x-encoded-double=<redacted>"))
        #expect(message.contains("x-encoded-final-layer=<redacted>"))
        #expect(message.contains("x-encoded-deep=<redacted>"))
        #expect(message.contains("x-encoded-malformed=<redacted>"))
        #expect(message.contains("x-percent-text=release%2Fbeta"))
        for secret in [
            "HEADER-USER",
            "HEADER-PASSWORD",
            "SINGLE-HEADER-QUERY-SECRET",
            "DOUBLE-USER",
            "DOUBLE-PASSWORD",
            "DOUBLE-HEADER-QUERY-SECRET",
            "FINAL-LAYER-QUERY-SECRET",
            "DEEP-HEADER-QUERY-SECRET",
            "MALFORMED-USER",
            "MALFORMED-PASSWORD",
        ] {
            #expect(!message.contains(secret))
        }
    }

    private func makeRequestID() -> RequestID {
        guard let rawValue = UUID(uuidString: "00000000-0000-0000-0000-000000000021") else {
            Issue.record("The fixed test request identity must be a valid UUID")
            return RequestID(rawValue: UUID())
        }

        return RequestID(rawValue: rawValue)
    }

    private func messageForRequestHeader(_ name: String, value: String) throws -> String {
        let fieldName = try #require(HTTPField.Name(name), "The test header name must be valid")
        var headers = HTTPFields()
        headers[fieldName] = value
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

        return NetworkLoggerFormatter(configuration: .init()).format(event).message
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

private final class LocalizedErrorDescriptionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private struct RecordedLocalizedError: Error, LocalizedError, CustomNSError, Sendable {
    static var errorDomain: String {
        "RecordedLocalizedError"
    }

    let recorder: LocalizedErrorDescriptionRecorder

    var errorCode: Int {
        errorDescription == nil ? 0 : 1
    }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? ""]
    }

    var errorDescription: String? {
        recorder.recordInvocation()
        return "LOCALIZED-DESCRIPTION-SECRET"
    }
}

private struct RecordedCustomNSError: Error, CustomNSError, Sendable {
    static var errorDomain: String {
        "CUSTOM-ERROR-DOMAIN-SECRET"
    }

    let code: Int
    let recorder: LocalizedErrorDescriptionRecorder

    var errorCode: Int {
        code
    }

    var errorUserInfo: [String: Any] {
        recorder.recordInvocation()
        return [NSLocalizedDescriptionKey: "CUSTOM-ERROR-USERINFO-SECRET"]
    }
}

private struct DiagnosticArgumentBox<Content> {}

private enum GenericDiagnosticContainer<Context> {
    enum FirstKey: DiagnosticRequestContextKey {
        typealias Value = String

        static func diagnosticDescription(for value: String) -> String {
            "first=\(value)"
        }
    }

    enum SecondKey: DiagnosticRequestContextKey {
        typealias Value = String

        static func diagnosticDescription(for value: String) -> String {
            "second=\(value)"
        }
    }

    struct NestedDiagnosticError: Error {}
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
