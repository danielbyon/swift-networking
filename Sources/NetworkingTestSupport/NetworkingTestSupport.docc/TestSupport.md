# TestSupport

Use `NetworkingTestSupport` with a real `NetworkClient` and a ``MockNetworkTransport``. The test exercises endpoint construction, request modifiers, adapters, authentication, retry decisions, and response decoding while the mock controls transport results. Unmatched requests fail inside the mock; they never reach a live network.

```swift
import Foundation
import Networking
import NetworkingTestSupport

let endpoint = Endpoint<Never, Never, Data>.data(
    method: .get,
    route: .absolute(URL(string: "https://api.example.com/v1/status")!),
    response: .data
)
let request = Request(endpoint: endpoint)

let fixture = try JSONFixture(json: #"{"status":"ok"}"#)
let transport = MockNetworkTransport(stubs: [
    try NetworkStub(
        matching: .path("/v1/status"),
        response: fixture.httpStubResponse()
    )
])
let client = try NetworkClient.testing(transport: transport)

let response = try await client.send(request)
let body = response.value
```

`NetworkClient.testing(configuration:transport:dependencies:)` installs the supplied mock and test dependencies. It does not add a public production transport-injection path. Stubs are consumed once by default; select `.finite(_:)` or `.always` when a scenario needs repeated responses. Matchers inspect the final request received by the transport, after request adapters and authentication.

`RequestMatcher` provides method, path, URL, query, header, body, attempt-number, and semantic JSON matching. Combine matchers with `and(_:)`, `or(_:)`, and `not()`; header and query matchers can use exact or subset semantics. The mock records requests by attempt and request identifier. Use `recordedRequests()`, `recordedRequestsByRequestID()`, and the verification methods to assert consumption, ordering, and cancellation. Use `NetworkTestDependencies` to make retry sleeps immediate and provide deterministic wall-clock time and jitter. Configure deterministic logical request IDs separately with `NetworkClient.Configuration.withRequestIDGenerator(_:)`, using `StaticRequestIDGenerator` or `SequenceRequestIDGenerator`.

`JSONFixture` validates JSON once and provides semantic matchers, decoders, and stub responses. Object key order does not affect semantic matching, array order is preserved, and numbers compare exactly. Bundle-resource loading requires the caller to pass the bundle explicitly. The SnapshotTesting integration provides `recordedRequest`, `attemptHistory`, `networkEvents`, `response(_:)`, and `json` strategies. Stability projections preserve mandatory privacy redaction, even when callers select exact treatment for unstable values. Snapshot strategies are available on iOS, macOS, tvOS, and watchOS. On visionOS the non-SnapshotTesting test support remains available, but the SnapshotTesting integration is not.

For simple asynchronous requests, see the [Networking Getting Started guide](https://github.com/danielbyon/swift-networking/blob/main/Sources/Networking/Networking.docc/GettingStarted.md).
