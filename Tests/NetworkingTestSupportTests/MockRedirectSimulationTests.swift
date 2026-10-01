//
//  MockRedirectSimulationTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Networking
import Synchronization
import Testing
@testable import NetworkingTestSupport

@Test("A redirect chain stays within one stub, one attempt, and one logical identity")
func redirectChainStaysWithinOneAttempt() async throws {
    let startURL = try #require(URL(string: "https://mock.example/start"))
    let hopURL = try #require(URL(string: "https://mock.example/hop"))
    let finalURL = try #require(URL(string: "https://mock.example/final"))
    let recorder = NetworkEventRecorder()
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 302, location: hopURL),
                    proposedRequest: URLRequest(url: hopURL),
                ),
                StubRedirect(
                    response: redirectResponse(status: 307, location: finalURL),
                    proposedRequest: URLRequest(url: finalURL),
                ),
            ],
            followedBy: .httpResponse(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let configuration = NetworkClient.Configuration().withEventObserver(recorder.observer)
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)

    let response = try await client.send(redirectRequest(url: startURL))
    _ = try await recorder.waitForTerminalEvent(for: response.requestID)

    #expect(response.value == Data([0x2a]))
    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
    #expect(recorded.first?.attemptNumber == 1)
    #expect(recorded.first?.requestID == response.requestID)
    try await transport.verifyAllFiniteStubsConsumed()
    let groups = await transport.recordedRequestsByRequestID()
    #expect(groups.count == 1)
    #expect(groups.first?.attempts.count == 1)

    let decisions = recorder.recordedEvents(for: response.requestID).compactMap { event -> RedirectDecisionEvent? in
        guard case let .redirectDecision(decision) = event else {
            return nil
        }

        return decision
    }
    #expect(decisions.map(\.redirectOrdinal) == [1, 2])
    #expect(decisions.map(\.decision) == [.follow, .follow])
    #expect(decisions.map(\.attemptNumber) == [1, 1])
    #expect(decisions.map(\.httpResponse.status.code) == [302, 307])
    #expect(decisions.map(\.proposedRequest.path) == ["/hop", "/final"])
    #expect(decisions.allSatisfy { $0.requestID == response.requestID })
}

@Test("A custom redirect policy receives the proposed Foundation request unchanged")
func customRedirectPolicyReceivesProposedRequest() async throws {
    let startURL = try #require(URL(string: "https://mock.example/start"))
    let hopURL = try #require(URL(string: "https://mock.example/hop"))
    var proposedRequest = URLRequest(url: hopURL)
    proposedRequest.httpMethod = "PUT"
    proposedRequest.httpBody = Data([0x01, 0x02])
    proposedRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let policy = RedirectPolicy.custom(maximumRedirects: 3) { context in
        guard context.currentRequest.url == startURL,
              context.currentRequest.httpMethod == "GET",
              context.proposedRequest.url == hopURL,
              context.proposedRequest.httpMethod == "PUT",
              context.proposedRequest.httpBody == Data([0x01, 0x02]),
              context.proposedRequest.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream",
              context.redirectOrdinal == 1,
              context.attemptNumber == 1
        else {
            return .reject
        }

        return .follow
    }
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 307, location: hopURL),
                    proposedRequest: proposedRequest,
                ),
            ],
            followedBy: .httpResponse(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let endpoint = redirectEndpoint(url: startURL, redirectPolicy: policy)

    let response = try await client.send(Request(endpoint: endpoint))

    #expect(response.value == Data([0x2a]))
    #expect(response.httpResponse.status.code == 200)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("A rejected redirect ends the attempt with the redirect response and its body")
func rejectedRedirectEndsAttemptWithRedirectResponse() async throws {
    let startURL = try #require(URL(string: "https://mock.example/rejected-start"))
    let hopURL = try #require(URL(string: "https://mock.example/rejected-hop"))
    let recorder = NetworkEventRecorder()
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 302, location: hopURL),
                    proposedRequest: URLRequest(url: hopURL),
                    body: Data([0x0a]),
                ),
            ],
            followedBy: .httpResponse(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let configuration = NetworkClient.Configuration().withEventObserver(recorder.observer)
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)
    let endpoint = redirectEndpoint(
        url: startURL,
        redirectPolicy: .reject,
        validationPolicy: .custom { _ in .accept },
    )

    let response = try await client.send(Request(endpoint: endpoint))
    _ = try await recorder.waitForTerminalEvent(for: response.requestID)

    #expect(response.httpResponse.status.code == 302)
    #expect(response.value == Data([0x0a]))
    #expect(response.attempts.map(\.outcome) == [.acceptedResponse])
    let decisions = recorder.recordedEvents(for: response.requestID).compactMap { event -> RedirectDecisionEvent? in
        guard case let .redirectDecision(decision) = event else {
            return nil
        }

        return decision
    }
    #expect(decisions.map(\.decision) == [.reject])
    #expect(await transport.recordedRequests().count == 1)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("A rejected redirect on a download attempt delivers the redirect body as a file")
func rejectedRedirectOnDownloadDeliversRedirectBody() async throws {
    let startURL = try #require(URL(string: "https://mock.example/download-start"))
    let hopURL = try #require(URL(string: "https://mock.example/download-hop"))
    let body = Data([0x0b, 0x0c])
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 303, location: hopURL),
                    proposedRequest: URLRequest(url: hopURL),
                    body: body,
                ),
            ],
            followedBy: .download(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let endpoint = redirectDownloadEndpoint(
        url: startURL,
        redirectPolicy: .reject,
        validationPolicy: .custom { _ in .accept },
    )

    let response = try await client.send(Request(endpoint: endpoint))

    #expect(response.httpResponse.status.code == 303)
    #expect(try Data(contentsOf: response.value.url) == body)
    try await transport.verifyAllFiniteStubsConsumed()
}

@Test("Exceeding the redirect limit carries supplied metrics and attempt history")
func exceedingRedirectLimitCarriesSuppliedMetrics() async throws {
    let startURL = try #require(URL(string: "https://mock.example/limited-start"))
    let hopURL = try #require(URL(string: "https://mock.example/limited-hop"))
    let finalURL = try #require(URL(string: "https://mock.example/limited-final"))
    let metrics = NormalizedAttemptMetrics(duration: .seconds(0.25), redirectCount: 1)
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 302, location: hopURL),
                    proposedRequest: URLRequest(url: hopURL),
                ),
                StubRedirect(
                    response: redirectResponse(status: 307, location: finalURL),
                    proposedRequest: URLRequest(url: finalURL),
                ),
            ],
            followedBy: .httpResponse(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
        metrics: metrics,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let client = try NetworkClient.testing(transport: transport)
    let endpoint = redirectEndpoint(url: startURL, redirectPolicy: .follow(maximumRedirects: 1))

    do {
        _ = try await client.send(Request(endpoint: endpoint))
        Issue.record("Expected the redirect limit to fail the logical request")
    } catch let error as RedirectError {
        guard case let .tooManyRedirects(requestID, maximumRedirects, lastResponse, attempts) = error else {
            Issue.record("Expected a too-many-redirects error")
            return
        }

        #expect(maximumRedirects == 1)
        #expect(lastResponse?.status.code == 307)
        #expect(attempts.count == 1)
        let attempt = try #require(attempts.first)
        #expect(attempt.requestID == requestID)
        #expect(attempt.attemptNumber == 1)
        #expect(attempt.outcome == .redirectLimitExceeded)
        #expect(attempt.normalizedMetrics == metrics)
        #expect(attempt.rawTaskMetrics == nil)
    }

    #expect(await transport.recordedRequests().count == 1)
    try await transport.verifyAllFiniteStubsConsumed()
}

private func redirectResponse(status: Int, location: URL) -> HTTPResponse {
    var fields = HTTPFields()
    if let locationName = HTTPField.Name("Location") {
        fields[locationName] = location.absoluteString
    }
    return HTTPResponse(status: .init(code: status), headerFields: fields)
}

@Test("An unrepresentable scripted redirect proposal fails before the policy evaluates it")
func unrepresentableScriptedRedirectProposalFailsBeforePolicyEvaluation() async throws {
    let startURL = try #require(URL(string: "https://mock.example/unrepresentable-start"))
    let requestID = RequestID(rawValue: UUID())
    let metrics = NormalizedAttemptMetrics(duration: .seconds(0.1), networkProtocolName: "h2")
    let evaluatedProposals = Mutex(0)
    let policy = RedirectPolicy.custom(maximumRedirects: 3) { _ in
        evaluatedProposals.withLock { $0 += 1 }
        return .follow
    }
    var unrepresentableRequest = URLRequest(url: startURL)
    unrepresentableRequest.url = nil
    let stub = try NetworkStub(
        matching: .method(.get),
        response: .redirect(
            proposals: [
                StubRedirect(
                    response: redirectResponse(status: 302, location: startURL),
                    proposedRequest: unrepresentableRequest,
                ),
            ],
            followedBy: .httpResponse(
                data: Data([0x2a]),
                response: HTTPResponse(status: .init(code: 200)),
            ),
        ),
        metrics: metrics,
    )
    let transport = MockNetworkTransport(stubs: [stub])
    let recorder = NetworkEventRecorder()
    let configuration = NetworkClient.Configuration()
        .withEventObserver(recorder.observer)
        .withRequestIDGenerator(StaticRequestIDGenerator(requestID: requestID))
    let client = try NetworkClient.testing(configuration: configuration, transport: transport)
    let endpoint = redirectEndpoint(url: startURL, redirectPolicy: policy)

    do {
        _ = try await client.send(Request(endpoint: endpoint))
        Issue.record("Expected the unrepresentable redirect proposal to fail the logical request")
    } catch let error as NetworkTestSupportError {
        guard case .redirectRequiresRepresentableRequest = error else {
            Issue.record("Expected redirectRequiresRepresentableRequest, received \(error)")
            return
        }
    }

    _ = try await recorder.waitForTerminalEvent(for: requestID)
    #expect(evaluatedProposals.withLock { $0 } == 0)
    let events = recorder.recordedEvents(for: requestID)
    #expect(!events.contains { event in
        if case .redirectDecision = event {
            return true
        }

        return false
    })
    let failedAttempt = events.compactMap { event -> AttemptFailedEvent? in
        guard case let .attemptFailed(failedAttempt) = event else {
            return nil
        }

        return failedAttempt
    }
    .first
    #expect(failedAttempt?.normalizedMetrics == metrics)
    #expect(failedAttempt?.rawTaskMetrics == nil)
    #expect(await transport.recordedRequests().count == 1)
    try await transport.verifyAllFiniteStubsConsumed()
}

private func redirectRequest(url: URL) -> Request<Data> {
    Request(endpoint: redirectEndpoint(url: url, redirectPolicy: .follow))
}

private func redirectEndpoint(
    url: URL,
    redirectPolicy policy: RedirectPolicy,
    validationPolicy: ResponseValidationPolicy? = nil,
) -> Endpoint<Never, Never, Data> {
    var endpoint = Endpoint<Never, Never, Data>.data(
        method: .get,
        route: .absolute(url),
        response: .data,
    )
    .redirectPolicy(policy)
    if let validationPolicy {
        endpoint = endpoint.validationPolicy(validationPolicy)
    }
    return endpoint
}

private func redirectDownloadEndpoint(
    url: URL,
    redirectPolicy policy: RedirectPolicy,
    validationPolicy: ResponseValidationPolicy? = nil,
) -> Endpoint<Never, Never, DownloadedFile> {
    var endpoint = Endpoint<Never, Never, DownloadedFile>.download(
        method: .get,
        route: .absolute(url),
    )
    .redirectPolicy(policy)
    if let validationPolicy {
        endpoint = endpoint.validationPolicy(validationPolicy)
    }
    return endpoint
}
