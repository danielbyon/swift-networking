//
//  NetworkLogger.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import os

/// Formats lifecycle events as privacy-aware diagnostics for Apple's unified logging system.
///
/// The application supplies the logger so it can choose the subsystem and category. Register
/// ``eventObserver`` through ``NetworkClient/Configuration/withEventObserver(_:)`` to receive
/// diagnostics through the same asynchronous, bounded event delivery used by other observers.
public struct NetworkLogger: Sendable {
    /// Controls which request metadata and retained body bytes may appear in diagnostics.
    public struct Configuration: Sendable {
        /// Selects whether already-retained response body bytes may be rendered.
        public enum BodyDiagnostics: Sendable, Equatable {
            /// Omits response body bytes from every diagnostic.
            case disabled

            /// Renders at most the configured number of bytes from an already-retained response body.
            ///
            /// A zero-byte limit emits body metadata without body text. File-backed bodies are never read.
            case enabled(maximumBytes: UInt)
        }

        /// Additional HTTP field names whose values are redacted case-insensitively.
        ///
        /// Authorization, Proxy-Authorization, Cookie, and Set-Cookie are always redacted and cannot be removed.
        public let additionalSensitiveHeaders: Set<String>

        /// The opt-in policy for rendering retained response body bytes.
        public let bodyDiagnostics: BodyDiagnostics

        /// Creates privacy settings for a logger observer.
        ///
        /// - Parameters:
        ///   - additionalSensitiveHeaders: Extra HTTP field names whose values must be redacted.
        ///   - bodyDiagnostics: Whether to render already-retained response bytes and the maximum byte count.
        public init(
            additionalSensitiveHeaders: Set<String> = [],
            bodyDiagnostics: BodyDiagnostics = .disabled,
        ) {
            self.additionalSensitiveHeaders = additionalSensitiveHeaders
            self.bodyDiagnostics = bodyDiagnostics
        }
    }

    /// The observer to register with a network client to receive formatted lifecycle diagnostics.
    public let eventObserver: NetworkEventObserver

    /// Creates a diagnostic observer using an application-owned Apple logger.
    ///
    /// - Parameters:
    ///   - logger: The logger that owns subsystem and category selection.
    ///   - configuration: The privacy settings for header and body diagnostics.
    public init(logger: Logger, configuration: Configuration = .init()) {
        let formatter = NetworkLoggerFormatter(configuration: configuration)
        eventObserver = NetworkEventObserver { event in
            let diagnostic = formatter.format(event)
            switch diagnostic.level {
            case .info:
                logger.info("\(diagnostic.message, privacy: .public)")
            case .error:
                logger.error("\(diagnostic.message, privacy: .public)")
            }
        }
    }
}

package struct NetworkLoggerDiagnostic: Sendable, Equatable {
    package enum Level: Sendable, Equatable {
        case info
        case error
    }

    package let level: Level
    package let message: String
}

/// Builds stable text records before any value reaches Apple's logger interpolation.
package struct NetworkLoggerFormatter: Sendable {
    private let sensitiveHeaderNames: Set<String>
    private let bodyDiagnostics: NetworkLogger.Configuration.BodyDiagnostics

    package init(configuration: NetworkLogger.Configuration) {
        sensitiveHeaderNames = NetworkPrivacySanitizer.mandatorySensitiveHeaderNames.union(
            configuration.additionalSensitiveHeaders.map { $0.lowercased() },
        )
        bodyDiagnostics = configuration.bodyDiagnostics
    }

    package func format(_ event: NetworkEvent) -> NetworkLoggerDiagnostic {
        var fields: [String] = []
        let level: NetworkLoggerDiagnostic.Level

        switch event {
        case let .requestStarted(event):
            fields = ["event=request_started", requestID(event.requestID)]
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .attemptStarted(event):
            fields = [
                "event=attempt_started",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "method=\(safe(event.request.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.request))",
                "request_headers=\(headers(event.request.headerFields))",
            ]
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .responseReceived(event):
            fields = [
                "event=response_received",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "method=\(safe(event.request.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.request))",
                response(event.httpResponse),
            ]
            appendMetrics(event.normalizedMetrics, to: &fields)
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .attemptFailed(event):
            fields = [
                "event=attempt_failed",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "method=\(safe(event.request.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.request))",
                "error=\(errorSummary(event.error))",
            ]
            if let httpResponse = event.httpResponse {
                fields.append(response(httpResponse))
            }
            appendMetrics(event.normalizedMetrics, to: &fields)
            appendContext(event.requestContext, to: &fields)
            level = .error

        case let .authenticationReplayScheduled(event):
            fields = [
                "event=authentication_replay_scheduled",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "method=\(safe(event.request.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.request))",
                response(event.httpResponse),
            ]
            appendMetrics(event.normalizedMetrics, to: &fields)
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .retryScheduled(event):
            fields = [
                "event=retry_scheduled",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "method=\(safe(event.request.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.request))",
                "delay=\(NetworkPrivacySanitizer.duration(event.delay))",
            ]
            if let httpResponse = event.httpResponse {
                fields.append(response(httpResponse))
            }
            if let transportError = event.transportError {
                fields.append("error=\(errorSummary(transportError))")
            }
            appendMetrics(event.normalizedMetrics, to: &fields)
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .redirectDecision(event):
            fields = [
                "event=redirect_decision",
                requestID(event.requestID),
                "attempt=\(event.attemptNumber)",
                "redirect_ordinal=\(event.redirectOrdinal)",
                "method=\(safe(event.proposedRequest.method.rawValue))",
                "url=\(NetworkPrivacySanitizer.requestURLShape(event.proposedRequest))",
                response(event.httpResponse),
                "decision=\(event.decision == .follow ? "follow" : "reject")",
            ]
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .requestCompleted(event):
            fields = [
                "event=request_completed",
                requestID(event.requestID),
                response(event.httpResponse),
                "attempt_count=\(event.attempts.count)",
            ]
            for attempt in event.attempts {
                append(attempt, to: &fields)
            }
            appendContext(event.requestContext, to: &fields)
            level = .info

        case let .requestFailed(event):
            fields = [
                "event=request_failed",
                requestID(event.requestID),
                "error=\(errorSummary(event.error))",
            ]
            if case let .enabled(maximumBytes) = bodyDiagnostics,
               let validationError = event.error as? ResponseValidationError,
               let retainedBody = validationError.retainedBody {
                fields.append(NetworkPrivacySanitizer.bodyDescription(retainedBody, maximumBytes: maximumBytes))
            }
            appendContext(event.requestContext, to: &fields)
            level = .error

        case let .requestCancelled(event):
            fields = ["event=request_cancelled", requestID(event.requestID)]
            appendContext(event.requestContext, to: &fields)
            level = .info
        }

        return NetworkLoggerDiagnostic(level: level, message: fields.joined(separator: " "))
    }

    private func requestID(_ requestID: RequestID) -> String {
        "request_id=\(requestID.rawValue.uuidString)"
    }

    private func response(_ response: HTTPResponse) -> String {
        "status=\(response.status.code) response_headers=\(headers(response.headerFields))"
    }

    private func headers(_ fields: HTTPFields) -> String {
        NetworkPrivacySanitizer.headers(fields, sensitiveHeaderNames: sensitiveHeaderNames)
    }

    private func appendMetrics(_ metrics: NormalizedAttemptMetrics, to fields: inout [String], prefix: String = "") {
        if let duration = metrics.duration {
            fields.append("\(prefix)duration=\(NetworkPrivacySanitizer.duration(duration))")
        }
        if let redirectCount = metrics.redirectCount {
            fields.append("\(prefix)redirect_count=\(redirectCount)")
        }
        if let requestBytes = metrics.requestBodyBytesSent {
            fields.append("\(prefix)request_bytes=\(requestBytes)")
        }
        if let responseBytes = metrics.responseBodyBytesReceived {
            fields.append("\(prefix)response_bytes=\(responseBytes)")
        }
        if let networkProtocolName = metrics.networkProtocolName {
            fields.append("\(prefix)protocol=\(safe(networkProtocolName))")
        }
        if let isReusedConnection = metrics.isReusedConnection {
            fields.append("\(prefix)reused_connection=\(isReusedConnection)")
        }
        if let resourceFetchType = metrics.resourceFetchType {
            fields.append("\(prefix)resource_fetch=\(safe(String(describing: resourceFetchType)))")
        }
    }

    private func append(_ attempt: AttemptMetrics, to fields: inout [String]) {
        let prefix = "attempt_\(attempt.attemptNumber)_"
        fields.append("\(prefix)outcome=\(outcome(attempt.outcome))")
        appendMetrics(attempt.normalizedMetrics, to: &fields, prefix: prefix)
    }

    private func appendContext(_ context: RequestContext, to fields: inout [String]) {
        let values = context.diagnosticRepresentation
            .sorted { $0.key < $1.key }
            .map { "\(safe($0.key))=\(safe($0.value))" }
        if values.isEmpty == false {
            fields.append("context=[\(values.joined(separator: ","))]")
        }
    }

    private func errorSummary(_ error: any Error) -> String {
        switch error {
        case let error as RequestConstructionError:
            error.errorDescription ?? "RequestConstructionError"
        case let error as ResponseValidationError:
            NetworkPrivacySanitizer.responseValidationErrorDescription(
                error,
                sensitiveHeaderNames: sensitiveHeaderNames,
            )
        case let error as RedirectError:
            NetworkPrivacySanitizer.redirectErrorDescription(
                error,
                sensitiveHeaderNames: sensitiveHeaderNames,
            )
        case let error as DownloadFileError:
            error.errorDescription ?? "DownloadFileError"
        default:
            NetworkPrivacySanitizer.errorIdentity(error)
        }
    }

    private func outcome(_ outcome: AttemptOutcome) -> String {
        switch outcome {
        case .transportFailure:
            "transport_failure"
        case .retryScheduled:
            "retry_scheduled"
        case .authenticationReplayScheduled:
            "authentication_replay_scheduled"
        case .acceptedResponse:
            "accepted_response"
        case .validationRejection:
            "validation_rejection"
        case .redirectLimitExceeded:
            "redirect_limit_exceeded"
        }
    }

    private func safe(_ value: String) -> String {
        NetworkPrivacySanitizer.escape(value)
    }
}

/// Shared privacy rules for logger records and library-owned error descriptions.
enum NetworkPrivacySanitizer {
    static let mandatorySensitiveHeaderNames: Set = ["authorization", "cookie", "proxy-authorization", "set-cookie"]

    static func requestURLShape(_ request: HTTPRequest) -> String {
        guard let path = request.path else {
            return "<url-unavailable>"
        }

        if let scheme = request.scheme, let authority = request.authority {
            return urlShape(from: "\(scheme)://\(authority)\(path)")
        }
        return urlShape(from: path)
    }

    static func urlShape(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<url-unavailable>"
        }

        return urlShape(from: components)
    }

    static func headers(_ fields: HTTPFields, sensitiveHeaderNames: Set<String>) -> String {
        let normalizedSensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        var renderedFields: [(String, String)] = []
        for field in fields {
            let name = field.name.canonicalName
            let value: String =
                if normalizedSensitiveHeaderNames.contains(name.lowercased()) {
                    "<redacted>"
                } else {
                    headerValue(field.value, name: name)
                }
            renderedFields.append((name, value))
        }
        renderedFields.sort { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        let descriptions = renderedFields.map { name, value in
            "\(escape(name))=\(value)"
        }
        return "[\(descriptions.joined(separator: ","))]"
    }

    static func duration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let formatted = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        var trimmed = formatted
        while trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.append("0")
        }
        return "\(trimmed)s"
    }

    static func bodyDescription(_ body: RetainedBody, maximumBytes: UInt) -> String {
        let maximumCount = maximumBytes > UInt(Int.max) ? Int.max : Int(maximumBytes)
        let retainedCount = body.data.count
        let cappedCount = min(retainedCount, maximumCount)
        let wasTruncated = body.isTruncated || cappedCount < retainedCount

        guard maximumCount > 0 else {
            return [
                "body=omitted",
                "emitted_bytes=0",
                "retained_bytes=\(retainedCount)",
                "original_bytes=\(body.originalByteCount)",
                "truncated=\(wasTruncated)",
            ].joined(separator: " ")
        }
        guard let validByteCount = validUTF8PrefixByteCount(
            in: body.data,
            maximumCount: cappedCount,
            retainedBodyIsTruncated: body.isTruncated,
        ) else {
            return "body=binary retained_bytes=\(retainedCount) original_bytes=\(body.originalByteCount) truncated=\(wasTruncated)"
        }

        let emittedText = String(decoding: body.data.prefix(validByteCount), as: UTF8.self)
        let didTrimScalar = validByteCount < cappedCount
        let truncated = wasTruncated || didTrimScalar
        return [
            "body=text",
            "content=\(escape(emittedText))",
            "emitted_bytes=\(validByteCount)",
            "retained_bytes=\(retainedCount)",
            "original_bytes=\(body.originalByteCount)",
            "truncated=\(truncated)",
        ].joined(separator: " ")
    }

    /// Validates only the capped prefix plus at most three continuation bytes. A truncated retained
    /// body may end at an incomplete scalar, but malformed continuation bytes still fail.
    private static func validUTF8PrefixByteCount(
        in data: Data,
        maximumCount: Int,
        retainedBodyIsTruncated: Bool,
    ) -> Int? {
        var index = 0

        while index < maximumCount {
            let firstByte = data[index]
            if firstByte <= 0x7f {
                index += 1
                continue
            }

            let sequenceLength: Int
            let secondByteMinimum: UInt8
            let secondByteMaximum: UInt8
            switch firstByte {
            case 0xc2 ... 0xdf:
                sequenceLength = 2
                secondByteMinimum = 0x80
                secondByteMaximum = 0xbf
            case 0xe0 ... 0xef:
                sequenceLength = 3
                secondByteMinimum = firstByte == 0xe0 ? 0xa0 : 0x80
                secondByteMaximum = firstByte == 0xed ? 0x9f : 0xbf
            case 0xf0 ... 0xf4:
                sequenceLength = 4
                secondByteMinimum = firstByte == 0xf0 ? 0x90 : 0x80
                secondByteMaximum = firstByte == 0xf4 ? 0x8f : 0xbf
            default:
                return nil
            }

            let bytesAvailableInBody = data.count - index
            if bytesAvailableInBody < sequenceLength {
                guard retainedBodyIsTruncated else {
                    return nil
                }

                for offset in 1 ..< bytesAvailableInBody {
                    let byte = data[index + offset]
                    let minimum = offset == 1 ? secondByteMinimum : 0x80
                    let maximum = offset == 1 ? secondByteMaximum : 0xbf
                    guard byte >= minimum, byte <= maximum else {
                        return nil
                    }
                }
                return index
            }

            let bytesRemainingInPrefix = maximumCount - index
            for offset in 1 ..< sequenceLength {
                let byte = data[index + offset]
                let minimum = offset == 1 ? secondByteMinimum : 0x80
                let maximum = offset == 1 ? secondByteMaximum : 0xbf
                guard byte >= minimum, byte <= maximum else {
                    return nil
                }
            }

            if bytesRemainingInPrefix < sequenceLength {
                return index
            }
            index += sequenceLength
        }

        return maximumCount
    }

    static func responseValidationErrorDescription(
        _ error: ResponseValidationError,
        sensitiveHeaderNames: Set<String> = mandatorySensitiveHeaderNames,
    ) -> String {
        [
            "Response validation failed",
            "request_id=\(error.requestID.rawValue.uuidString)",
            "status=\(error.httpResponse.status.code)",
            "response_headers=\(headers(error.httpResponse.headerFields, sensitiveHeaderNames: sensitiveHeaderNames))",
            "attempts=\(error.attempts.count)",
        ].joined(separator: " ")
    }

    static func redirectErrorDescription(
        _ error: RedirectError,
        sensitiveHeaderNames: Set<String> = mandatorySensitiveHeaderNames,
    ) -> String {
        switch error {
        case let .tooManyRedirects(requestID, maximumRedirects, lastResponse, attempts):
            var description = [
                "Redirect limit exceeded",
                "request_id=\(requestID.rawValue.uuidString)",
                "maximum_redirects=\(maximumRedirects)",
                "attempts=\(attempts.count)",
            ].joined(separator: " ")
            if let lastResponse {
                description += " " + [
                    "status=\(lastResponse.status.code)",
                    "response_headers=\(headers(lastResponse.headerFields, sensitiveHeaderNames: sensitiveHeaderNames))",
                ].joined(separator: " ")
            }
            return description
        }
    }

    static func downloadFileErrorDescription(_ error: DownloadFileError) -> String {
        switch error {
        case let .finalizationFailed(source, destination, underlyingError):
            [
                "Download finalization failed",
                "source=\(urlShape(source))",
                "destination=\(urlShape(destination))",
                "underlying=\(errorIdentity(underlyingError))",
            ].joined(separator: " ")
        case let .moveFailed(source, destination, underlyingError):
            [
                "Download move failed",
                "source=\(urlShape(source))",
                "destination=\(urlShape(destination))",
                "underlying=\(errorIdentity(underlyingError))",
            ].joined(separator: " ")
        case let .removeFailed(url, underlyingError):
            [
                "Download removal failed",
                "url=\(urlShape(url))",
                "underlying=\(errorIdentity(underlyingError))",
            ].joined(separator: " ")
        }
    }

    static func requestConstructionErrorDescription(_ error: RequestConstructionError) -> String {
        let reason =
            switch error.reason {
            case .relativeRouteRequiresBaseURL:
                "relative route requires a base URL"
            case .missingURLScheme:
                "absolute route has no URL scheme"
            case .unsupportedURLScheme:
                "absolute route uses an unsupported URL scheme"
            case .urlCompositionFailed:
                "URL composition failed"
            case .urlQueryEncoding:
                "URL query encoding failed"
            case .queryCompositionFailed:
                "query composition failed"
            case .unreadableFileBody:
                "file-backed request body is unavailable"
            case .unsupportedOperationBodyCombination:
                "request body is incompatible with the selected operation"
            }
        return "Request construction failed request_id=\(error.requestID.rawValue.uuidString) reason=\(reason)"
    }

    static func errorIdentity(_ error: any Error) -> String {
        let type = String(reflecting: Swift.type(of: error))
        let foundationError = error as NSError
        return "\(escape(type))(domain=<redacted>,code=\(foundationError.code))"
    }

    static func escape(_ value: String) -> String {
        value
            .replacing("\\", with: "\\\\")
            .replacing("\n", with: "\\n")
            .replacing("\r", with: "\\r")
            .replacing("\t", with: "\\t")
            .replacing("\"", with: "\\\"")
            .replacing(" ", with: "\\s")
            .replacing("=", with: "\\=")
            .replacing(",", with: "\\,")
            .replacing("[", with: "\\[")
            .replacing("]", with: "\\]")
    }

    private static func headerValue(_ value: String, name: String) -> String {
        switch name {
        case "location",
             "content-location",
             "referer":
            quotedURLShape(from: value)
        case "link":
            quoted(linkHeaderShape(value))
        default:
            if value.contains("://") || value.contains("?") {
                quotedURLShape(from: value)
            } else {
                escape(value)
            }
        }
    }

    private static func quotedURLShape(from value: String) -> String {
        quoted(urlShape(from: value))
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            .replacing("\n", with: "\\n")
            .replacing("\r", with: "\\r")
            .replacing("\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func linkHeaderShape(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "<([^>]+)>") else {
            return "<link-redacted>"
        }

        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        let urls = expression.matches(in: value, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range(at: 1), in: value) else {
                return nil
            }

            return "<\(urlShape(from: String(value[matchRange])))>"
        }
        return urls.isEmpty ? "<link-redacted>" : urls.joined(separator: ",")
    }

    private static func urlShape(from value: String) -> String {
        guard let components = URLComponents(string: value) else {
            return "<url-unavailable>"
        }

        return urlShape(from: components)
    }

    private static func urlShape(from source: URLComponents) -> String {
        let path = source.percentEncodedPath
        let base: String
        if let scheme = source.scheme, let host = source.host {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = source.port
            components.percentEncodedPath = path
            base = components.string ?? "<url-unavailable>"
        } else if let scheme = source.scheme, scheme.lowercased() == "file" {
            base = "file://\(path)"
        } else if let scheme = source.scheme {
            base = "\(scheme):\(path)"
        } else if let host = source.host {
            base = "//\(host)\(path)"
        } else {
            base = path
        }

        guard let query = source.percentEncodedQuery else {
            return base
        }

        let redactedQuery = query
            .split(separator: "&", omittingEmptySubsequences: false)
            .lazy
            .map { pair in
                let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return "\(diagnosticQueryName(name))=<redacted>"
            }
            .joined(separator: "&")
        return "\(base)?\(redactedQuery)"
    }

    private static func diagnosticQueryName(_ name: Substring) -> String {
        String(name)
            .replacing(" ", with: "%20")
            .replacing(",", with: "%2C")
            .replacing("[", with: "%5B")
            .replacing("]", with: "%5D")
    }
}

extension RequestConstructionError: LocalizedError {
    /// A privacy-safe summary of the request construction failure.
    public var errorDescription: String? {
        NetworkPrivacySanitizer.requestConstructionErrorDescription(self)
    }
}

extension ResponseValidationError: LocalizedError {
    /// A privacy-safe summary of the rejected response that omits its optional reason text.
    public var errorDescription: String? {
        NetworkPrivacySanitizer.responseValidationErrorDescription(self)
    }
}

extension RedirectError: LocalizedError {
    /// A privacy-safe summary of the redirect limit failure.
    public var errorDescription: String? {
        NetworkPrivacySanitizer.redirectErrorDescription(self)
    }
}

extension DownloadFileError: LocalizedError {
    /// A privacy-safe summary of the file operation and underlying error identity.
    public var errorDescription: String? {
        NetworkPrivacySanitizer.downloadFileErrorDescription(self)
    }
}
