# Networking 1.0 conformance and release readiness

This document is the durable conformance and release-readiness record for the Networking 1.0 release
candidate of the `swift-networking` package. It maps every normative section and cross-cutting
invariant of the approved specification to concrete implementation, test, documentation, tooling, or
release evidence, states the remaining actions required before the `1.0.0` tag, and records the
follow-ups that the specification explicitly defers to after 1.0.

## 1. Authority and reading guide

- Normative behavior contract: [`docs/spec/networking-1.0.md`](../docs/spec/networking-1.0.md). The
  specification is frozen for 1.0. This document records evidence about the repository; it never
  restates a requirement differently and never weakens one.
- Domain vocabulary and the compact invariant map: [`CONTEXT.md`](../CONTEXT.md).
- Accepted decision rationale: [`docs/adr/`](../docs/adr/).
- Architecture map: [`Documentation/Architecture.md`](Architecture.md).
- Agent workflow and verified commands: [`Documentation/AgentGuide.md`](AgentGuide.md).

Evidence cited below comes from four sources:

1. implementation symbols and files under `Sources/Networking` and `Sources/NetworkingTestSupport`;
2. tests under `Tests/NetworkingTests` and `Tests/NetworkingTestSupportTests`, written with Swift
   Testing; a test name quoted below can be located by searching that name in the test targets;
3. documentation: the two DocC catalogs under `Sources/Networking/Networking.docc` and
   `Sources/NetworkingTestSupport/NetworkingTestSupport.docc`, `README.md`, and the agent documents;
4. tooling and release metadata: `Makefile`, `Scripts/`, `.githooks/`, `.github/workflows/`,
   `.swiftformat`, `.swiftlint.yml`, `Package.swift`, `Package.resolved`, `LICENSE`, and the GitHub
   repository configuration.

Status values used in the matrices:

- **Conformant** - implemented and verified by the cited evidence.
- **Conformant, deferred** - the specification explicitly permits the deferred part; recorded under
  post-1.0 follow-ups.
- **Corrected** - the audit found a gap, and the row records the fix and its evidence.
- **Non-conformant** - not currently satisfied; the row records the exact section, the observed
  state, and the required action.

Every normative requirement audited here is conformant. Section 7.1 lists the maintainer
release operations that remain before the `1.0.0` tag, and section 8 records the
follow-ups that the specification defers to after 1.0.

## 2. Specification section matrix

### 2.1 Project definition and package (sections 1-3)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 1.1 | Identity: repository and package `swift-networking`; products `Networking` and `NetworkingTestSupport`; MIT license. | `Package.swift` (package name and the two library products); `LICENSE` (MIT, Copyright (c) 2026 Daniel Byon); GitHub repository metadata reports license `mit`. | Conformant |
| 1.2 | Repository posture: publicly visible; issues enabled and collaborator-only; pull requests enabled and collaborator-only; Discussions disabled; the owner is the only human collaborator apart from authorized automation; the README ends with the public-reference/no-public-support notice; SemVer is honored after 1.0.0. | GitHub GraphQL `repository`: `visibility = PUBLIC`, `isPrivate = false`, `hasIssuesEnabled = true`, `hasDiscussionsEnabled = false`, `issueCreationPolicy = COLLABORATORS_ONLY`, `pullRequestCreationPolicy = COLLABORATORS_ONLY`; REST repository metadata: `has_issues = true`, `has_pull_requests = true`, `has_discussions = false`, `private = false`. Collaborators: `danielbyon` (admin) only, no pending invitations. README section "Public reference". Refreshed on 2026-10-05 after the owner changed both creation policies; see section 9. | **Conformant** - collaborator-only issue and pull-request creation verified live on 2026-10-05. |
| 1.3 | Purpose: shared networking infrastructure for the owner applications, progressive-disclosure API, and first-class testing infrastructure. | `README.md` introduction and capabilities; DocC `GettingStarted.md` and `TestSupport.md`; `Documentation/Architecture.md`. | Conformant |
| 1.4 | Supported platforms are exactly iOS, macOS, tvOS, watchOS, and visionOS 27+; Windows and Linux are unsupported. | `Package.swift` platform list; `README.md` platform table; CI platform matrix; five successful `make platform-build` compilations. | Conformant |
| 1.5 | Swift tools 6.4, Swift 6 language mode, complete strict-concurrency checking, no library-authored `@unchecked Sendable`, `nonisolated(unsafe)`, or equivalent unchecked escape hatch. | `Package.swift` (`swift-tools-version: 6.4`, `swiftLanguageModes: [.v6]`); a source scan of `Sources/` finds no `@unchecked Sendable` and no `nonisolated(unsafe)`; the package builds without compiler warnings. | Conformant |
| 2.1 | Production dependencies are limited to Swift HTTP Types. | `Package.swift`: `swift-http-types` from 1.8.0, used as `HTTPTypes` and `HTTPTypesFoundation`; `Package.resolved` pins the resolved revision. | Conformant |
| 2.2 | Testing and TestSupport dependencies must not leak into the production product. | `Package.swift` target graph: the `Networking` target depends only on HTTP Types; `NetworkingTestSupport` adds the snapshot-testing products conditionally; the test targets add them for their own use. | Conformant |
| 3 | Two-module package: `Networking` (production) and `NetworkingTestSupport` (testing), with the internal transport abstraction kept package-internal and out of the public production extensibility surface. | `package protocol NetworkTransport` in `Sources/Networking/NetworkClient.swift`; the only public way to supply a transport is `NetworkClient.testing(configuration:transport:dependencies:)` in `Sources/NetworkingTestSupport/NetworkClientTesting.swift`; no public transport protocol appears in the public symbol graph. | Conformant |

### 2.2 Core model, endpoint, and routing (sections 4-7)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 4 | Core model is Endpoint, then Request, then NetworkClient, then NetworkTask, then Response, where an attempt is one real URLSession task. | `Sources/Networking/Endpoint.swift`, `Request.swift`, `NetworkClient.swift`, `NetworkTask.swift`, `Response.swift`; `CONTEXT.md` sections "Operation model" and "Execution pipeline"; `Documentation/Architecture.md`. | Conformant |
| 5.1 | `Endpoint<Input, Body, Output>` with `Sendable` constraints and strategy-specific constraints added only by the selected strategy. | `Endpoint.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`; `Tests/NetworkingTests/UploadAndFileBodyTests.swift`. | Conformant |
| 5.2 | `Never` means the dimension does not exist, and convenience overloads remove `Never` ceremony at ordinary call sites. | `Endpoint.swift` factory overloads; `README.md` quick start uses `Endpoint<Never, Never, Data>`; `Tests/NetworkingTests/NetworkingTests.swift`. | Conformant |
| 5.3 | Operation-specific factories `.data`, `.upload`, and `.download`; an explicit HTTP method is always required. | `Endpoint.swift`; `Tests/NetworkingTests/UploadAndFileBodyTests.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift`. | Conformant |
| 5.4 | Operation semantics: data responses are handled in memory; uploads use upload-task semantics for data and file bodies; downloads return `DownloadedFile` and reject file-backed request bodies during preflight. | `Endpoint.swift`; `NetworkClient.swift` preflight; `Tests/NetworkingTests/UploadAndFileBodyTests.swift` ("File-backed request bodies fail download preflight before progress, adapters, or transport"). | Conformant |
| 5.5 | The endpoint is an immutable value; configuration modifiers return derived copies. | `Endpoint.swift`; ADR 0003; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 5.6 | The endpoint owns method, route, query contract, headers, body contract, decoding contract, authentication requirement, and policy overrides; a request cannot redefine them. | `Endpoint.swift`, `Request.swift`; ADR 0003; `Tests/NetworkingTests/RequestAdapterTests.swift`. | Conformant |
| 6.1 | Public `EndpointRoute<Input>` whose input-derived factories require a concrete input witness that is never retained. | `Endpoint.swift`; ADR 0001; `Tests/NetworkingTests/RoutingTests.swift`. | Conformant |
| 6.2 | Relative routes are structured, percent-encoded path components appended to the client base URL. | `EndpointRoute.relative(forInput:)`; `Tests/NetworkingTests/RoutingTests.swift` ("Relative route components stay encoded within configured base path", "An empty relative component remains one empty path segment"). | Conformant |
| 6.3 | Absolute routes derive a URL from input or use a fixed URL; the scheme must be HTTP or HTTPS; embedded query items form the lowest-precedence query layer; fragments are stripped; client default query items do not apply. | `Endpoint.swift`; ADR 0001 and ADR 0002; `Tests/NetworkingTests/RoutingTests.swift` ("Absolute route fragments removed before transport", "Unsupported absolute route schemes fail before transport with execution ID", "Absolute routes without schemes fail before transport"). | Conformant |
| 7 | `NetworkClient.Configuration.baseURL` is optional; relative routes without it fail with `RequestConstructionError`; a base URL must be HTTP or HTTPS and contain no query or fragment. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift` ("Configuration validation aggregates base URL and timeout failures in contract order", "Base URL validation aggregates only scheme query and fragment failures in order"). | Conformant |

### 2.3 Query and body encoding (sections 8-10)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 8.1 | `QueryEncoding<Input>` with `.none`, `.items`, and `.codable`; input-bearing factories take closures directly, without a witness value. | `QueryEncoding.swift`; `Tests/NetworkingTests/QueryCompositionTests.swift`. | Conformant |
| 8.2 | `URLQueryEncoder` defaults and explicit failures: nil omitted, empty string preserved, Bool literal, Date ISO-8601, arrays repeated key; unsupported containers throw documented errors. | `URLQueryEncoder.swift`; `Tests/NetworkingTests/URLQueryEncoderTests.swift`. | Conformant |
| 8.3 | `.codable` may select a subvalue of the input instead of the whole input. | `QueryEncoding.swift`; `Tests/NetworkingTests/QueryCompositionTests.swift`. | Conformant |
| 8.4 | Deterministic query output: lexical key ordering for encoded keys, preserved element order, and caller order for `[URLQueryItem]`. | `Sources/Networking/QueryComposer.swift`; `Tests/NetworkingTests/QueryCompositionTests.swift`. | Conformant |
| 8.5 | Client-wide query-encoder defaults are configurable on the client. | `NetworkClient.Configuration`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |
| 8.6 | Query merge precedence: relative routes merge client defaults, then endpoint query, then request query; absolute routes merge the embedded absolute-URL query, then endpoint query, then request query, and client default query items are omitted. A higher-precedence layer removes lower-layer occurrences of the same key while repeated values within one layer are preserved. | `Sources/Networking/QueryComposer.swift` (`QueryComposer.compose` seeds absolute routes from the embedded URL query and relative routes from client defaults); ADR 0002; `Tests/NetworkingTests/QueryCompositionTests.swift` (`relativeQueryLayersUsePrecedence`, `absoluteQueryCollisionUsesSemanticKeys`). | Conformant |
| 9.1 | `BodyEncoding<Body>` with `.json`, `.data`, `.file`, and `.custom` forms. | `BodyEncoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 9.2 | JSON encoding uses a fresh library-owned encoder per operation, applies client configuration first and endpoint configuration second, defaults to `application/json`, and permits an explicit media-type override. | `BodyEncoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 9.3 | Raw `Data` bodies use `.data(contentType:)` without a custom encoder. | `BodyEncoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 9.4 | File bodies use `.file(contentType:)`, never infer a MIME type, must stay available and stable, and are verified readable before the corresponding attempt. | `BodyEncoding.swift`; `Tests/NetworkingTests/UploadAndFileBodyTests.swift` ("A file removed before ordinary retry fails without starting another transport attempt", "An initially missing file fails before general and authentication adaptation"). | Conformant |
| 9.5 | Custom encoding is a synchronous throwing operation that produces replayable in-memory data. | `BodyEncoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift` ("Custom body encoding runs during execution and preserves thrown errors"). | Conformant |
| 9.6 | Built-in 1.0 bodies are replayable, and replayability is inferred by the library. | `BodyEncoding.swift`; `CONTEXT.md`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`. | Conformant |
| 9.7 | The body is serialized independently for every attempt; encoding failures happen before the attempt and create no attempt number or metrics. | `NetworkClient.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift` ("Body encoding errors occur before adapters", "JSON encoding propagates native EncodingError before transport"); `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |
| 10.1 | `ResponseDecoding<Output>` with `.json`, `.data`, `.empty`, and `.custom` strategies. | `ResponseDecoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 10.2 | JSON decoding uses a fresh library-owned decoder per operation with client-then-endpoint configuration. | `ResponseDecoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 10.3 | Raw responses use `.data` for `Output == Data`. | `ResponseDecoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 10.4 | `EmptyResponse` is `Sendable`, `Equatable`, `Hashable`, `Codable` with a public zero-argument initializer; `EmptyResponseBodyPolicy` defaults to `.ignore`. | `ResponseDecoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 10.5 | Custom decoding has the documented `@Sendable (Data, HTTPResponse) throws -> Output` shape and propagates native and custom errors unchanged. | `ResponseDecoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift` ("Custom response decoding receives response metadata and preserves thrown errors"). | Conformant |
### 2.4 Headers, request, context, and identity (sections 11-14)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 11 | Header precedence is inferred defaults, then client, then endpoint, then request, then adapters, then authentication, with `HTTPFields` multi-value semantics preserved. | `Sources/Networking/HeaderComposer.swift`; `Tests/NetworkingTests/HeaderCompositionTests.swift`; `Tests/NetworkingTests/RequestAdapterTests.swift`. | Conformant |
| 12.1 | After construction, generic input and body information is erased and `Request<Output>` is the invocation value. | `Request.swift`; ADR 0003; `Tests/NetworkingTests/NetworkingTests.swift`. | Conformant |
| 12.2 | Canonical initializers exist for bodyful, bodyless, and no-input requests; downloads default to a temporary destination. | `Request.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 12.3 | `Request.init` is non-throwing; it captures invocation values, resolves non-throwing builders, and defers deterministic serialization that may fail later. | `Request.swift`; `Tests/NetworkingTests/RequestContextTests.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 12.4 | Request construction does not perform networking and captures route, header, and explicit query state immutably. | `Request.swift`; ADR 0003; `Tests/NetworkingTests/RequestAdapterTests.swift`. | Conformant |
| 12.5 | Immutable modifiers exist for headers, single headers, query items, request timeout, retry policy, validation policy, redirect policy, cache policy, HTTP/3 preference, and context; there is no body modifier, no authentication override, and no decoder override. | `Request.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`; `Tests/NetworkingTests/RequestAdapterTests.swift`. | Conformant |
| 12.6 | Request query items merge by key and override lower-precedence occurrences; 1.0 has no arbitrary query-replacement API. | `QueryComposer.swift`; `Tests/NetworkingTests/QueryCompositionTests.swift`. | Conformant |
| 13 | `RequestContext` and `RequestContextKey` with optional values, replacement on repeated set, and unchanged propagation across adapters, authentication replay, ordinary retry, response, observability, and TestSupport recording. | `RequestContext.swift`; `Tests/NetworkingTests/RequestContextTests.swift`; `Tests/NetworkingTestSupportTests/NetworkRecorderTests.swift`. | Conformant |
| 13.1 | Context is private to logging and snapshots by default; `DiagnosticRequestContextKey` opts a key in, identified by its fully qualified Swift type name. | `RequestContext.swift`, `NetworkLogger.swift`; `Tests/NetworkingTests/RequestContextTests.swift`, `Tests/NetworkingTests/NetworkLoggerTests.swift`. | Conformant |
| 14.1 | `RequestID` is `Hashable`, `Sendable`, and `Codable`, wrapping a `UUID`. | `RequestID.swift`; `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift`. | Conformant |
| 14.2 | `RequestIDGenerator` is `Sendable`; generation is synchronous, non-throwing, exactly once per logical execution, and happens before preflight, adapters, authentication, and transport; `UUIDRequestIDGenerator` is the default. | `RequestID.swift`; `Sources/NetworkingTestSupport/RequestIDGenerators.swift`; `Tests/NetworkingTestSupportTests/RequestIDGeneratorsTests.swift`; `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift`. | Conformant |
| 14.3 | Attempts are numbered from 1 with `UInt`, share one monotonically increasing sequence across retries and authentication replays, and are identified by request ID plus attempt number. | `NetworkClient.swift`, `AttemptMetrics.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`, `Tests/NetworkingTests/AuthenticationTests.swift`, `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |

### 2.5 Client, session, and policies (sections 15-18)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 15.1 | `NetworkClient` is a final, internally concurrency-safe `Sendable` reference type and not an actor, so request starts are not serialized behind actor isolation. | `NetworkClient.swift`; ADR 0004; `Documentation/Architecture.md`. | Conformant |
| 15.2 | Canonical construction uses an immutable `NetworkClient.Configuration` built with fluent modifiers. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |
| 15.3 | Initialization validates the complete configuration before constructing the client, reports all discoverable failures together in a stable, deterministic order, and throws `NetworkClient.ConfigurationError`. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift` ("Configuration validation aggregates base URL and timeout failures in contract order"). | Conformant |
| 15.4 | The client owns the full `URLSession` lifecycle, creates exactly one foreground session per client, permits no arbitrary session injection or session templates, and does not cancel in-flight operations on deinitialization. | `NetworkClient.swift`; ADR 0004; `Tests/NetworkingTests/NetworkingTests.swift` ("foreground URL session configuration disables shared state"). | Conformant |
| 16 | The supported client-level controls exist (base URL, headers, static query, codecs, policies, cache, cookies, timeouts, connectivity flags, HTTP/3 preference, request ID generator, authentication provider, adapters, observers), and unsupported injection forms are rejected or absent. | `NetworkClient.Configuration`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |
| 17.1 | Cache policy and `URLCache?` are client configuration with Foundation-compatible behavior. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |
| 17.2 | `HTTPCookieStorage?` semantics: `nil` disables cookies and is the default; a supplied storage is used exactly; cookie storage is client-wide. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkingTests.swift`. | Conformant |
| 17.3 | The internally created session disables ambient URL credential storage, and the library never stores application credentials. | `NetworkClient.swift`; ADR 0005; `Tests/NetworkingTests/NetworkingTests.swift`. | Conformant |
| 18 | Timeouts are wire and session concerns: request timeout precedence is client, then endpoint, then request; resource timeout is client-only; `Duration?` values must be greater than zero; `nil` preserves Foundation behavior. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |

### 2.6 Authentication, adapters, and pipeline (sections 19-22)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 19.1 | Authentication is endpoint-owned through `AuthenticationRequirement` with `.none` default and `.required(maximumReplays:)`; there is no client-level default and no request-level override. | `Authentication.swift`; ADR 0005; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 19.2 | `.required(maximumReplays: 0)` still performs the initial authentication adaptation, never calls `recover`, and leaves ordinary retry independent. | `Authentication.swift`, `NetworkClient.swift`; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 19.3 | `AuthenticationProvider` coordinates adaptation and recovery, owns credentials and refresh externally, may inspect response and body context, never exposes credentials to the library, and a missing provider fails before attempt 1 with `AuthenticationConfigurationError`. | `Authentication.swift`; ADR 0005; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 19.4 | Authentication replay has an independent budget, is immediate without backoff, regenerates the body, reruns adapters and adaptation, and increments the global attempt number. | `NetworkClient.swift`; ADR 0006; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 20 | `RequestAdapter` is client-level and ordered, `AnyRequestAdapter` provides type erasure and closure backing, adapters may modify the request but not the prepared body, and adapter errors fail the request without transport. | `RequestAdapter.swift`; ADR 0006; `Tests/NetworkingTests/RequestAdapterTests.swift` ("An adapter error propagates unchanged and prevents transport"). | Conformant |
| 21 | `PreparedRequestBody` with `.none`, `.data(Data)`, and `.file(URL)` is inspection-only for adapters and authentication. | `BodyEncoding.swift`; `Tests/NetworkingTests/RequestAdapterTests.swift`; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 22 | The documented execution pipeline order holds, including per-attempt body preparation, adapters, authentication adaptation as the final outgoing mutation stage, authentication recovery before ordinary retry, retry before validation, validation before decoding or finalization, and no attempt number or metrics for pre-transport failures. | `NetworkClient.swift`; `CONTEXT.md` section "Execution pipeline"; `Tests/NetworkingTests/NetworkEventTests.swift` ("Preflight failure follows request start and has no attempt events"); `Tests/NetworkingTests/DownloadExecutionTests.swift` ("File-backed request bodies fail download preflight before progress, adapters, or transport" asserts no attempt number, no adapter calls, and zero transport executions); `Tests/NetworkingTests/AuthenticationTests.swift` ("A required request without a provider fails before body preparation, adapters, or transport"). | Conformant |

### 2.7 Retry, validation, response, metrics, and progress (sections 23-28)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 23.1 | `RetryPolicy` is an immutable value type whose ordinary budget is one initial attempt plus `maximumRetries`, which defaults to 0. | `RetryPolicy.swift` (`maximumRetries = 0`); ADR 0006; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.2 | The core policy covers retryable methods, retryable statuses, transient transport classification, backoff, Retry-After handling, and an optional custom decision hook; endpoint and request overrides replace the inherited policy. | `RetryPolicy.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.3 | Default retryable methods are GET, HEAD, OPTIONS, TRACE, PUT, and DELETE; POST, PATCH, and custom methods are excluded. | `RetryPolicy.swift` (default method set); `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.4 | Default retryable statuses are 408, 429, 500, 502, 503, and 504, and the set is publicly inspectable and configurable. | `RetryPolicy.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.5 | The transient transport set covers connectivity, timeout, connection loss, DNS, and connect failures, and excludes cancellation, malformed requests, certificate failures, and authentication configuration errors; the set is public rather than hidden. | `RetryPolicy.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`. | Conformant |
| 23.6 | Retry vocabulary is nested beneath the policy: backoff strategy, jitter, Retry-After policy, decision, and reason. | `RetryPolicy.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.7 | Backoff strategies are immediate, constant, linear, and exponential with finite maximum delays and overflow-safe arithmetic. | `RetryPolicy.swift`, `Sources/Networking/RetryTiming.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.8 | Retry-After supports both delay and HTTP-date forms, past dates become zero delay, the default maximum accepted server delay is 60 seconds, and the maximum is configurable including unlimited. | `RetryTiming.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift` ("Retry-After HTTP dates resolve against injected wall clock"). | Conformant |
| 23.9 | The custom retry decision hook is synchronous, runs after built-in classification, may override the built-in decision, cannot choose its own delay, and cannot inspect response bodies. | `RetryPolicy.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 23.10 | Backoff delays use cancellable clock semantics, and cancellation during backoff prevents the next attempt. | `RetryTiming.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`. | Conformant |
| 24.1 | `ResponseValidationPolicy` is an immutable closure-backed value; `successfulStatusCodes` accepts 200 to 299 and is the default; higher-precedence policies replace lower ones. | `ResponseValidationPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 24.2 | Validation receives the response, the received body, the request ID, and the request context. | `ResponseValidationPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 24.3 | `ReceivedResponseBody` is `.data` for in-memory responses and `.file` for downloads; file access is read-only for the callback lifetime and prevents loading large downloads into memory. | `ResponseValidationPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 24.4 | Validation results are `accept` and `reject`; rejections become `ResponseValidationError`, and custom validators do not throw arbitrary errors. | `ResponseValidationPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 24.5 | Retry runs before validation, so retryable statuses are retried before the default policy rejects them. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 25.1 | Successful data and upload responses retain raw bodies only under `BodyRetentionPolicy`; downloads are never read back into memory. | `BodyRetentionPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 25.2 | Validation-failure retention defaults to unlimited and follows client, endpoint, request precedence, with explicit truncation metadata when configured. | `BodyRetentionPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 25.3 | `RetainedBody` carries data, original byte count, and truncation state, with `Sendable`, `Equatable`, and `Hashable` conformances that include every semantic field. | `BodyRetentionPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift` ("Unlimited retention preserves sliced Data indices in body diagnostics"). | Conformant |
| 26 | `Response<Value>` carries value, HTTP response, request ID, attempt metrics, and optional retained body; downloads return `Response<DownloadedFile>` with no raw-body duplicate. | `Response.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift`, `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |
| 26.1 | Conditional `Equatable` and `Hashable` conformances include every semantic field, and closure-bearing `Endpoint` and `Request` do not conform in 1.0. | `Response.swift`, `Endpoint.swift`, `Request.swift`; `Tests/NetworkingTests/AttemptMetricsTests.swift` ("Response equality and hashing include attempt history"). | Conformant |
| 27 | Every real task creates one `AttemptMetrics` record with request ID, attempt number, normalized metrics, diagnostic outcome, and optional raw Foundation metrics; the terminal response retains metrics for every preceding attempt and retains no bodies. | `AttemptMetrics.swift`, `NetworkClient.swift`; ADR 0006; `Tests/NetworkingTests/AttemptMetricsTests.swift` ("Success exposes one accepted attempt logical request identity", "Legacy transport adapter preserves thrown error and reports no raw metrics"). | Conformant |
| 28.1 | `NetworkProgress` counts are never fabricated or clamped. | `NetworkProgress.swift`; `Tests/NetworkingTests/NetworkProgressTests.swift`. | Conformant |
| 28.2 | Initial per-attempt progress is an unknown attempt number with zero byte counts and `isComplete` false; expected totals may be published immediately when known. | `NetworkProgress.swift`; `Tests/NetworkingTests/NetworkProgressTests.swift`, `Tests/NetworkingTests/URLSessionTransportProgressTests.swift`. | Conformant |
| 28.3 | Progress describes the current attempt only; retries and replays reset counters and publish a new attempt state without accumulating history. | `NetworkProgress.swift`; `Tests/NetworkingTests/NetworkClientProgressTests.swift`, `Tests/NetworkingTests/URLSessionTransportProgressTests.swift`. | Conformant |
| 28.4 | `isComplete` is set only when the whole logical operation succeeds; decoding failures, rejections, replayed uploads, and finalization failures never publish successful terminal progress, and terminal progress cannot be displaced. | `NetworkProgress.swift`, `NetworkTask.swift`; ADR 0007; `Tests/NetworkingTests/NetworkClientProgressTests.swift` ("Decoder failure after complete byte transfer never publishes successful completion"). | Conformant |
### 2.8 Progress sequence, task, sending, downloads, redirects, protocol, observability, logging, and errors (sections 29-38)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 29 | `NetworkProgressSequence` is replaying, multicast, reusable, and per-iterator independent; late subscribers receive the latest state; at most one unseen non-terminal update is buffered per subscriber; a successful terminal update is never displaced; no history is stored. | `NetworkProgress.swift`; ADR 0007; `Tests/NetworkingTests/NetworkProgressTests.swift`, `Tests/NetworkingTests/NetworkClientProgressTests.swift`. | Conformant |
| 30 | `NetworkTask<Value>` is a `Sendable` final class exposing request ID, progress, value, and idempotent `cancel()`; all waiters share the stored terminal result; cancelling one waiter does not cancel the operation; releasing the last reference does not cancel it. | `NetworkTask.swift`; ADR 0006; `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift` ("Cancellation observed before admission wins over delivered terminal event"). | Conformant |
| 31 | `send(_:)` owns its task and propagates Swift task cancellation, `task(request:)` exposes the shared lifecycle, and endpoint conveniences mirror request construction without growing `send` parameters. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkingTests.swift`, `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift`. | Conformant |
| 32.1 | `DownloadDestination` supports temporary, fixed file with collision policy, and response-resolved destinations; response-based resolution runs only after validation succeeds. | `DownloadDestination.swift`, `NetworkClient.swift`; ADR 0008; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("A rejected response never resolves or touches a caller destination"). | Conformant |
| 32.2 | `DownloadCollisionPolicy` provides `failIfExists` and best-effort `replaceExisting`. | `DownloadDestination.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("A fixed destination collision preserves the caller file", "Replacing an existing destination succeeds and preserves downloaded contents"). | Conformant |
| 32.3 | Finalization ordering guarantees that retried or rejected responses never touch the caller destination and that successful finalization disarms cleanup of the old temporary path. | `NetworkClient.swift`; ADR 0008; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("A failed move preserves the current URL and existing destination", "A failed move keeps automatic cleanup armed for an untouched temporary download"). | Conformant |
| 32.4 | Rejected downloads retain a truncated diagnostic body, remove the temporary file, and throw `ResponseValidationError`; abandoned downloads are cleaned up on retry, replay, rejection, cancellation, or failure. | `NetworkClient.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("Rejected downloads retain the configured prefix and remove the file", "Cancellation during destination resolution discards the temporary file", "Authentication errors remove a materialized download file"). | Conformant |
| 33.1 | Temporary downloads are owned by `DownloadedFile` and may be removed automatically until the caller reads `url`; files placed at caller destinations are never auto-removed. | `DownloadedFile.swift`; ADR 0008; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("Removal is idempotent and deinitialization preserves a recreated path"). | Conformant |
| 33.2 | `move(destination:collisionPolicy:)` moves the owned file, updates the URL, disarms cleanup, honors the collision policy, and may be repeated; `remove()` is idempotent for an absent file and `url` still returns the previous location. | `DownloadedFile.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("Successful moves can be repeated for the current file location", "Repeated removal preserves a file recreated at the removed path"). | Conformant |
| 34.1 | `RedirectPolicy` provides `follow`, `reject`, `sameOriginOnly`, and `custom`; decisions are synchronous; precedence is client, endpoint, request; the default is `follow`. | `RedirectPolicy.swift`, `Sources/Networking/RedirectEvaluation.swift`; `Tests/NetworkingTests/RedirectPolicyTests.swift` ("Same-origin policy normalizes scheme and default ports"). | Conformant |
| 34.2 | The redirect limit defaults to 10, is configurable, treats 0 as no redirects, resets per attempt, and exceeding it throws `RedirectError.tooManyRedirects`. | `RedirectPolicy.swift`, `NetworkClient.swift`; `Tests/NetworkingTests/RedirectPolicyTests.swift` ("The default redirect policy follows with a ten redirect limit", "Redirect limits reset across authentication replay attempts"). | Conformant |
| 34.3 | Rejecting a redirect does not throw; the 3xx response becomes the final response and proceeds through validation. | `RedirectPolicy.swift`; `Tests/NetworkingTests/RedirectPolicyTests.swift` ("The reject policy rejects without consuming its configured redirect budget"). | Conformant |
| 34.4 | Foundation redirect semantics are respected: redirects are handled by the session, and adapters, authentication, and body preparation are not re-entered for a redirect. | `NetworkClient.swift`; `CONTEXT.md`; `Tests/NetworkingTests/RedirectPolicyTests.swift`, `Tests/NetworkingTestSupportTests/MockRedirectSimulationTests.swift`. | Conformant |
| 35 | The library implements no separate HTTP/2 or HTTP/3 transport, captures the negotiated protocol through metrics, and exposes the HTTP/3 first-attempt preference with client, endpoint, request precedence. | `NetworkClient.swift` (`assumesHTTP3Capable`), `Sources/Networking/TransportRequest.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`; `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |
| 36.1 | `NetworkEventObserver` is a closure-backed `Sendable` value whose synchronous, non-throwing callbacks are executed asynchronously and never awaited by the request workflow; observers are retained for the client lifetime. | `NetworkEvent.swift`; ADR 0007; `Tests/NetworkingTests/NetworkEventTests.swift`. | Conformant |
| 36.2 | Each observer has an independent bounded FIFO queue; a slow observer cannot block networking or another observer; submission follows registration order; overflow drops the oldest pending event; there is no synthetic drop diagnostic in 1.0. | `NetworkEvent.swift`; ADR 0007; `Tests/NetworkingTests/NetworkEventTests.swift`. | Conformant |
| 36.3 | The ten documented lifecycle events exist, every logical request emits exactly one terminal event, preflight failures emit started then failed with no attempt events, and `attemptStarted` precedes only a real task. | `NetworkEvent.swift`; `Tests/NetworkingTests/NetworkEventTests.swift`, `Tests/NetworkingTestSupportTests/NetworkRecorderTests.swift`. | Conformant |
| 36.4 | Events carry request ID, wall-clock and monotonic timestamps, and attempt or HTTP context as specified for each case. | `NetworkEvent.swift`; `Tests/NetworkingTests/NetworkEventTests.swift`. | Conformant |
| 37 | `NetworkLogger` is a built-in observer that logs method, URL shape, request ID, attempt number, status, duration, byte counts, retry, authentication-replay, and redirect data. | `NetworkLogger.swift`; `Tests/NetworkingTests/NetworkLoggerTests.swift`. | Conformant |
| 37.1 | Sensitive headers and all query values are redacted by default, bodies are never logged by default, opt-in body diagnostics are explicitly configured with a byte cap and skip file-backed and binary payloads, and localized error descriptions apply the same redaction. | `NetworkLogger.swift`; `Tests/NetworkingTests/NetworkLoggerTests.swift` ("Library-owned localized error descriptions redact header and URL query values", "Opaque URI payloads are redacted in URL and Link headers", "Backslash-delimited URL references are redacted in generic headers"). | Conformant |
| 38.1 | Native errors (`URLError`, `EncodingError`, `DecodingError`, custom encoder errors, adapter and provider errors) propagate unchanged, and explicit cancellation is normalized to `CancellationError`. | `NetworkClient.swift`; ADR 0009; `Tests/NetworkingTests/AttemptMetricsTests.swift` ("Metrics-aware transport failures propagate the original error unchanged"). | Conformant |
| 38.2 | There is no umbrella `NetworkError`; library-owned error types are `NetworkClient.ConfigurationError`, `RequestConstructionError`, `AuthenticationConfigurationError`, `ResponseValidationError`, `RedirectError`, and `DownloadFileError`, all `Sendable`, with honest `Equatable` or `Hashable` and `LocalizedError` where useful. | `Sources/Networking`; ADR 0009; `Tests/NetworkingTests/NetworkLoggerTests.swift`, `Tests/NetworkingTests/DownloadExecutionTests.swift`. | Conformant |
| 38.3 | `RequestConstructionError` covers relative route without base URL, unsupported scheme, URL and query composition failure, query-encoder failure, unreadable file body, and unsupported operation and body combination, and carries the request ID; arbitrary body-encoder errors are not wrapped. | `RequestConstructionError.swift`; `Tests/NetworkingTests/RoutingTests.swift`, `Tests/NetworkingTests/UploadAndFileBodyTests.swift`; `Tests/NetworkingTests/NetworkLoggerTests.swift` ("Every request construction reason has a stable safe description"). | Conformant |
| 38.4 | `AuthenticationConfigurationError` reports an endpoint that requires authentication while no provider is configured, before attempt 1. | `Authentication.swift`; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 38.5 | `ResponseValidationError` carries at least the HTTP response, an optional retained body, and the request ID. | `ResponseValidationPolicy.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift` ("Validation rejection exposes its attempt and reason"). | Conformant |
| 38.6 | `RedirectError` carries request ID, response, and redirect context. | `RedirectError.swift`; `Tests/NetworkingTests/RedirectPolicyTests.swift`. | Conformant |
| 38.7 | `DownloadFileError` reports finalization and lifecycle failures with source and destination context. | `DownloadDestination.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("A removal failure reports the current file URL"). | Conformant |

### 2.9 Cancellation, Combine, TestSupport, fixtures, snapshots, session policy, and unsupported features (sections 39-47)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 39 | Cancellation is cooperative across transport, retry sleeps, body preparation, adapters, and authentication; the library does not police non-cooperative user code. | `NetworkClient.swift`, `NetworkTask.swift`; `CONTEXT.md`; `Tests/NetworkingTests/NetworkClientProgressTests.swift`, `Tests/NetworkingTests/DownloadExecutionTests.swift`. | Conformant |
| 40.1 | `client.publisher(for:)` is a cold Combine publisher gated by `canImport(Combine)`; each subscription is a distinct logical execution, and cancelling a subscription cancels only its own operation. | `Sources/Networking/CombineBridges.swift`; `Tests/NetworkingTests/CombineBridgeTests.swift`. | Conformant |
| 40.2 | `valuePublisher` and `progressPublisher` bridge an existing shared task; individual subscriber cancellation never cancels the shared operation; late value subscribers receive the stored terminal result; progress follows the `NetworkProgressSequence` replay semantics. | `CombineBridges.swift`; ADR 0006 and ADR 0007; `Tests/NetworkingTests/CombineBridgeTests.swift`. | Conformant |
| 41.1 | `MockNetworkTransport` is a public, actor-backed TestSupport harness; test client creation is exposed only through TestSupport; the production transport abstraction stays package-internal. | `Sources/NetworkingTestSupport/MockNetworkTransport.swift`, `Sources/NetworkingTestSupport/NetworkClientTesting.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift` (26 tests). | Conformant |
| 41.2 | The stub vocabulary covers stubs, matching, responses, recording, consumption, latency, progress, metrics, and retry or authentication scripted flows. | `MockNetworkTransport.swift`, `Sources/NetworkingTestSupport/StubNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockScriptedExecutionTests.swift`. | Conformant |
| 41.3 | HTTP stub responses can produce status and headers with JSON content type and body. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/NetworkingTestSupportTests.swift`. | Conformant |
| 41.4 | Matchers compose method, URL or path, query, headers, body bytes, semantic JSON body, request context, attempt number, and custom closures with `and`, `or`, and `not`, and inspect the transport-ready request including authentication-added headers. | `Sources/NetworkingTestSupport/RequestMatcher.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift` ("Full URL matching rejects absent components while path and query remain usable", "Header subset and exact matching ignore field iteration order"). | Conformant |
| 41.5 | Unmatched attempts fail immediately with rich diagnostics describing the received request, available stubs, and mismatch reasons; no live I/O can occur. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift`. | Conformant |
| 41.6 | Every actual attempt is recorded by default with the transport-ready request, prepared-body diagnostics, request ID, attempt number, and context; file-backed uploads record URL and metadata without eagerly reading contents. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/NetworkRecorderTests.swift`. | Conformant |
| 41.7 | Framework-neutral verification helpers throw rich errors and cover stub consumption, request ordering, and cancellation propagation; there is no deinit-driven verification. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift` ("Explicit cancellation verification observes cancellation at transport start"). | Conformant |
| 41.8 | Redirect behavior is simulated explicitly within one stub attempt, exercises the redirect policy, limit, and lifecycle events, and does not consume another stub as a new logical attempt. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockRedirectSimulationTests.swift`. | Conformant |
| 41.9 | Stubs define deterministic data, upload, and download progress updates, and TestSupport provides a progress recorder that accumulates full history for assertions. | `MockNetworkTransport.swift`, `Sources/NetworkingTestSupport/NetworkProgressRecorder.swift`; `Tests/NetworkingTestSupportTests/MockScriptedExecutionTests.swift`. | Conformant |
| 41.10 | Mock operations record whether they were cancelled so tests can assert cancellation propagation. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift`. | Conformant |
| 41.11 | Stubs may supply normalized attempt metrics; raw Foundation metrics remain optional. | `MockNetworkTransport.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift`. | Conformant |
| 42.1 | JSON fixtures load from explicit bundle resources, inline strings, inline data, and encodable models, and never fall back to `Bundle.main`; missing resources produce diagnostic failures. | `Sources/NetworkingTestSupport/JSONFixture.swift`; `Tests/NetworkingTestSupportTests/JSONFixtureTests.swift`. | Conformant |
| 42.2 | Fixture decode and encode accept explicit configuration closures and never reach into client-private codec configuration. | `JSONFixture.swift`; `Tests/NetworkingTestSupportTests/JSONFixtureTests.swift`. | Conformant |
| 42.3 | Semantic JSON comparison ignores object key order, preserves array order, and compares numeric values exactly by default, with custom matchers for tolerances. | `Sources/NetworkingTestSupport/JSONSemanticMatcher.swift`, `Sources/NetworkingTestSupport/JSONCanonicalization.swift`; `Tests/NetworkingTestSupportTests/JSONFixtureTests.swift`. | Conformant |
| 42.4 | The `.json` snapshot strategy emits valid pretty-printed JSON with deterministic key ordering, and structured diagnostics use CustomDump. | `Sources/NetworkingTestSupport/Snapshotting+NetworkingTestSupport.swift`; `Tests/NetworkingTestSupportTests/SnapshotStrategyTests.swift`. | Conformant |
| 43 | Canonical snapshot strategies cover recorded requests, responses, attempt histories, event sequences, and JSON; generated values are sanitized by default with opt-in exact variants; the integration is unavailable on visionOS only because the released upstream dependency lacks visionOS support. | `Sources/NetworkingTestSupport/Snapshotting+NetworkingTestSupport.swift`, `Sources/NetworkingTestSupport/SnapshotStability.swift`, the `Snapshot*Projections.swift` files; `Tests/NetworkingTestSupportTests/SnapshotStrategyTests.swift`; `Package.swift` platform conditions; `README.md` platform note. | Conformant |
| 44 | `NetworkTestDependencies` supplies test-only clock, wall-clock, and jitter controls; request ID generators remain normal client configuration and are not moved into the test bundle; TestSupport supplies deterministic request ID generators and the event recorder. | `Sources/NetworkingTestSupport/NetworkTestDependencies.swift`, `Sources/NetworkingTestSupport/RequestIDGenerators.swift`; `Tests/NetworkingTestSupportTests/NetworkTestDependenciesTests.swift`, `Tests/NetworkingTestSupportTests/RequestIDGeneratorsTests.swift`. | Conformant |
| 45 | `NetworkEventRecorder` participates as a normal observer over the production asynchronous path and provides awaitable terminal helpers. | `Sources/NetworkingTestSupport/NetworkEventRecorder.swift`; `Tests/NetworkingTestSupportTests/NetworkRecorderTests.swift` ("A terminal waiter observes delivery after it starts waiting"). | Conformant |
| 46 | Foundation session defaults are preserved except for the three intentional deviations: URL cache, cookie storage, and credential storage default to disabled. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkingTests.swift` ("foreground URL session configuration disables shared state"). | Conformant |
| 47 | The unsupported 1.0 features (WebSockets, streaming responses and request bodies, background transfers, multipart encoding, TLS and client-certificate customization, Multipath TCP, arbitrary session injection, explicit client invalidation, custom HTTP/2 or HTTP/3 transports, post-download decoding pipelines) are absent from the public API, while the architecture keeps extension seams. | Public symbol inventory in the symbol graphs; `README.md` capabilities statement; ADR 0004; `Documentation/Architecture.md`. | Conformant |

### 2.10 Documentation, agent support, tooling, success criteria, invariants, and rejected alternatives (sections 48-54)

| Spec | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| 48 | Every public symbol has documentation comments; the DocC catalogs cover the 13 required guide topics; the README follows the required seven-section structure. | SwiftLint `missing_docs` rule enabled by the committed `.swiftlint.yml` baseline with zero violations; both DocC catalogs convert with warnings treated as errors; the 13 topics are distributed across `Sources/Networking/Networking.docc` (twelve guides) and `Sources/NetworkingTestSupport/NetworkingTestSupport.docc` (`TestSupport.md`); see section 3 below. | Conformant |
| 49 | Agent support deliverables exist: root `AGENTS.md`, `Documentation/AgentGuide.md`, the normative specification, architecture documentation, ADRs, build/test/lint/format commands, an issue-driven workflow, and at least one validated end-to-end coding-agent run. | Repository files; `docs/agents/`; ADRs 0001-0009; `Makefile`; the versioned end-to-end workflow record in `Documentation/AgentGuide.md` ("Recorded gpt-repo-local example") with GitHub issue 26, merged pull request 50, its green GitHub Actions runs, and the completed Codex review summary on that pull request; see section 4 below. | Conformant |
| 50 | SwiftFormat and SwiftLint use committed configuration, run locally through the pre-commit hook and in CI as mandatory checks; CI validates the build under Swift 6 strict concurrency, unit tests, TestSupport tests, and compilation for all five declared platforms; releases use SwiftPM source, Git tags, and GitHub Releases with no binary pipeline; API-baseline tooling is explicitly a post-1.0 item. | `.swiftformat`, `.swiftlint.yml`, `Scripts/swift-tools.sh`, `.githooks/pre-commit`, `Makefile`, `.github/workflows/ci.yml`; see section 4 below. | Conformant, deferred (API baseline) |
| 51 | All 19 release success criteria are met. | Section 5 below maps each criterion to evidence. | Conformant |
| 52 | All 32 cross-cutting invariants hold. | Section 6 below maps each invariant to evidence. | Conformant |
| 53 | The rejected alternatives stay rejected: no parallel endpoint hierarchies, no umbrella error, no public transport protocol, no runtime-mutable client configuration, no unlimited observer queues, no blocking observers, no progress history, no raw download duplication, no multipart, no streaming bodies, no background transfers, no logical timeout, no implicit authentication requirement, and no client query defaults on absolute URLs. | Public symbol inventory; `README.md` capabilities; ADRs 0002, 0004, and 0009; `Tests/NetworkingTests/QueryCompositionTests.swift`; `Tests/NetworkingTests/RedirectPolicyTests.swift`. | Conformant |
| 54 | Implementation decisions prioritize strict concurrency, determinism, explicit ownership, testability, and the endpoint and request model over local convenience. | Enforced by the change discipline in `AGENTS.md` and `CONTEXT.md`; verified by this audit, which made no behavior change to satisfy convenience. | Conformant |
## 3. Documentation conformance detail (section 48)

### 3.1 Public symbol documentation

Every public declaration is documented. The committed SwiftLint baseline enables the `missing_docs`
rule, which reports undocumented public declarations as errors, and the current sources produce no
violations. A compiler analysis of the emitted symbol graphs for both library targets confirms that
every public record without its own documentation comment is compiler-generated: extension-block
records, synthesized `==` and `!=` operators for `Equatable` conformances, `LocalizedError`
requirement implementations, `Sequence` and `AsyncSequence` witnesses, `Actor` conformance
witnesses, and `Decodable` requirement initializers. No hand-written public declaration lacks a
documentation comment: all 83 source-declared top-level public nominal types and their public
members carry documentation.

### 3.2 Required DocC guide topics

The specification requires 13 topics. Twelve are articles in `Sources/Networking/Networking.docc`, and
the TestSupport topic is the article in `Sources/NetworkingTestSupport/NetworkingTestSupport.docc`,
which is the catalog for the separate `NetworkingTestSupport` product. Together the two catalogs
cover the required list, and both catalogs convert with warnings treated as errors.

| Required topic | Article |
| --- | --- |
| Getting started | `Sources/Networking/Networking.docc/GettingStarted.md` |
| Endpoint and request model | `Sources/Networking/Networking.docc/EndpointAndRequest.md` |
| Body and query encoding | `Sources/Networking/Networking.docc/BodyAndQueryEncoding.md` |
| Authentication | `Sources/Networking/Networking.docc/Authentication.md` |
| Retries | `Sources/Networking/Networking.docc/Retries.md` |
| Validation | `Sources/Networking/Networking.docc/Validation.md` |
| Redirects | `Sources/Networking/Networking.docc/Redirects.md` |
| Uploads | `Sources/Networking/Networking.docc/Uploads.md` |
| Downloads | `Sources/Networking/Networking.docc/Downloads.md` |
| Progress and cancellation | `Sources/Networking/Networking.docc/ProgressAndCancellation.md` |
| Observability and logging | `Sources/Networking/Networking.docc/ObservabilityAndLogging.md` |
| Combine bridges | `Sources/Networking/Networking.docc/CombineBridges.md` |
| TestSupport | `Sources/NetworkingTestSupport/NetworkingTestSupport.docc/TestSupport.md` |

Each catalog also has a landing page that links every article, so no article is unreachable. The
`make docs-check` target validates both catalogs on the host platform, and the documentation CI job
runs that target.

### 3.3 README structure

`README.md` follows the required order and content: library purpose, quick start, major capabilities,
installation, documentation links, platform and support policy, and a final public-reference notice
stating that public support and external contributions are not accepted. The installation example is
explicitly described as a post-release example and does not claim that the release or tag exists.

## 4. Agent support and repository tooling detail (sections 49 and 50)

### 4.1 Agent support deliverables

| Deliverable | Location |
| --- | --- |
| Operational repository instructions | `AGENTS.md` |
| Agent workflow, reading order, command map, and issue process | `Documentation/AgentGuide.md` |
| Normative 1.0 specification | `docs/spec/networking-1.0.md` |
| Architecture map | `Documentation/Architecture.md` |
| Decision records | `docs/adr/0001` through `docs/adr/0009` |
| Issue tracker and triage guidance | `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, `docs/agents/domain.md` |
| Build, test, lint, and format commands | `Makefile`, `Scripts/swift-tools.sh`, `Documentation/AgentGuide.md` |
| Validated end-to-end coding-agent run | `Documentation/AgentGuide.md`, "Recorded gpt-repo-local example": the Issue 26 documentation run, with GitHub issue 26, merged pull request 50, its green GitHub Actions runs, and the completed Codex review summary on that pull request |

No repository-specific Skill is shipped, which matches the specification guidance that Skills are
created only for repeated workflows that have actually been identified.

### 4.2 Local and CI tooling

- `make lint` runs `git diff --check`, the pinned SwiftFormat in non-mutating lint mode with the
  committed `.swiftformat` configuration (it reports the files that require formatting instead of
  rewriting them), and the pinned SwiftLint with the committed `.swiftlint.yml` over `Sources`
  and `Tests`; `.githooks/pre-commit` invokes `make lint`, and the documented installation step
  is `make hooks-install`.
- `make format` applies the pinned SwiftFormat with the committed `.swiftformat` configuration.
- `make build` runs `swift build`; `make test` runs `swift test`; `make all` runs lint, build, and
  tests and is the CI quality job.
- `make docs-check` validates both DocC catalogs with symbol graphs and warnings treated as errors.
- `make platform-build PLATFORM=...` compiles the package scheme for a generic destination of each
  declared Apple platform.
- CI runs the quality job and a five-platform compile matrix (iOS, macOS, tvOS, watchOS, visionOS)
  plus the documentation job.
- Swift 6 strict concurrency is enforced by the package manifest (`swift-tools-version: 6.4` and
  `swiftLanguageModes: [.v6]`), so building the package is itself the strict-concurrency check, and
  the build completes without warnings.
- Releases use the SwiftPM source package with Git tags and GitHub Releases; there is no XCFramework
  or binary distribution pipeline, and no API-baseline tooling before the 1.0.0 tag, matching the
  specification. API-baseline tooling is recorded as follow-up F1.

## 5. Release success criteria (section 51)

| Criterion | Evidence | Status |
| --- | --- | --- |
| 1. Data, upload, and download operations are production-usable. | `Endpoint` factories and `NetworkClient` execution paths; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`, `UploadAndFileBodyTests.swift`, `DownloadExecutionTests.swift`; DocC `GettingStarted.md`, `Uploads.md`, `Downloads.md`. | Conformant |
| 2. Swift 6 strict concurrency works without consumer workarounds. | `Package.swift` language mode; warning-free build; no `@unchecked Sendable` or `nonisolated(unsafe)` in `Sources/`. | Conformant |
| 3. No library-authored unchecked concurrency escape hatch exists. | Source scan over `Sources/`; `@preconcurrency`, `fatalError`, `try!`, and `as!` do not appear either. | Conformant |
| 4. Endpoint and request APIs keep simple usage low-friction and customization progressive. | `README.md` quick start; DocC guides; `Endpoint.swift` and `Request.swift` modifier sets. | Conformant |
| 5. Codable JSON is first-class with raw and custom escapes available. | `BodyEncoding`, `ResponseDecoding`, `URLQueryEncoder`, `JSONFixture`; selected tests in the encoding and TestSupport suites. | Conformant |
| 6. Authentication never owns credentials and supports deterministic refresh and replay. | ADR 0005; `Authentication.swift`; `Tests/NetworkingTests/AuthenticationTests.swift`. | Conformant |
| 7. Retry behavior is explicit, bounded, testable, and disabled by default. | `RetryPolicy.swift` (`maximumRetries = 0`); `Tests/NetworkingTests/RetryPolicyTests.swift`, `NetworkClientRetryTests.swift`. | Conformant |
| 8. Validation, redirects, caching, cookies, timeouts, and HTTP/3 preference have deterministic precedence. | `NetworkClient.swift`, `ResponseValidationPolicy.swift`, `RedirectPolicy.swift`; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`, `RedirectPolicyTests.swift`, `ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 9. NetworkTask progress and cancellation semantics are deterministic and multicast-safe. | `NetworkTask.swift`, `NetworkProgress.swift`; ADR 0007; `Tests/NetworkingTests/NetworkProgressTests.swift`, `NetworkClientProgressTests.swift`, `RequestIDAndNetworkTaskTests.swift`. | Conformant |
| 10. Downloaded-file ownership and cleanup are explicit. | `DownloadedFile.swift`; ADR 0008; `Tests/NetworkingTests/DownloadExecutionTests.swift`. | Conformant |
| 11. Metrics retain the complete multi-attempt story. | `AttemptMetrics.swift`; `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |
| 12. Observability cannot delay networking execution. | `NetworkEvent.swift` bounded asynchronous observer queues; `Tests/NetworkingTests/NetworkEventTests.swift`; ADR 0007. | Conformant |
| 13. Logging is privacy-safe by default. | `NetworkLogger.swift`; `Tests/NetworkingTests/NetworkLoggerTests.swift`. | Conformant |
| 14. TestSupport exercises the full request pipeline without live network I/O. | `MockNetworkTransport.swift`, `NetworkClientTesting.swift`; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift`, `MockScriptedExecutionTests.swift`. | Conformant |
| 15. Retry, authentication, progress, redirect, and cancellation behavior are deterministically testable. | `Sources/NetworkingTestSupport/NetworkTestDependencies.swift`, `RetryTimingTestSupport.swift`, `NetworkProgressRecorder.swift`; `Tests/NetworkingTestSupportTests/MockScriptedExecutionTests.swift`, `MockRedirectSimulationTests.swift`, `NetworkTestDependenciesTests.swift`. | Conformant |
| 16. Public APIs are documented with DocC. | Section 3 above; both catalogs convert with warnings as errors. | Conformant |
| 17. Coding-agent documentation and workflows are present and validated. | Section 4 above; completed run records for Issues 26 and 27. | Conformant |
| 18. No known architectural blocker prevents later streaming, WebSocket, or background-transfer support. | ADR 0004 (session ownership and transport seam); `Documentation/Architecture.md` extension-seam notes; `docs/spec` section 47. | Conformant |
| 19. The public surface is small and coherent enough to honor SemVer after 1.0.0. | Public symbol inventory: 83 source-declared top-level public types across the two products, all mapped to specification concepts, with no synthesized or accidental exports. | Conformant |

## 6. Cross-cutting invariants (section 52)

| Invariant | Evidence | Status |
| --- | --- | --- |
| 1. Endpoint is the contract; Request is the invocation. | ADR 0003; `Endpoint.swift`, `Request.swift`. | Conformant |
| 2. Request and Endpoint are immutable values. | `Endpoint.swift`, `Request.swift`; ADR 0003. | Conformant |
| 3. NetworkClient runtime configuration is immutable. | `NetworkClient.swift`; ADR 0004; `Tests/NetworkingTests/NetworkClientConfigurationTests.swift`. | Conformant |
| 4. NetworkClient owns URLSession completely. | `NetworkClient.swift`; ADR 0004; `Tests/NetworkingTests/NetworkingTests.swift`. | Conformant |
| 5. No public production transport injection exists. | `package protocol NetworkTransport`; TestSupport-only `NetworkClient.testing`; public symbol graph. | Conformant |
| 6. No live network can escape MockNetworkTransport. | `MockNetworkTransport.swift` fails unmatched attempts with diagnostics; `Tests/NetworkingTestSupportTests/MockNetworkTransportTests.swift`. | Conformant |
| 7. One logical execution gets exactly one RequestID. | `RequestID.swift`; `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift`. | Conformant |
| 8. Attempt numbers correspond only to actual URLSession tasks. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkEventTests.swift` ("Preflight failure follows request start and has no attempt events", "A transport result marked not started emits no attempt events"); `Tests/NetworkingTests/DownloadExecutionTests.swift` ("File-backed request bodies fail download preflight before progress, adapters, or transport"); `Tests/NetworkingTests/NetworkClientRetryTests.swift` ("Retry metadata advances per consumed HTTP response before final validation"); `Tests/NetworkingTests/AuthenticationTests.swift` ("Authentication replay reconstructs the attempt and records its full recovery context"). | Conformant |
| 9. Attempt numbers start at 1 and increase monotonically across retries and authentication replay. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift` ("Retry metadata advances per consumed HTTP response before final validation", "Request retry policy replaces endpoint policy, which replaces client policy"); `Tests/NetworkingTests/AuthenticationTests.swift` ("Authentication replay reconstructs the attempt and records its full recovery context", "Authentication replay and ordinary retry use separate budgets and one chronological attempt sequence"). | Conformant |
| 10. The request body is regenerated independently for each attempt. | `NetworkClient.swift`, `BodyEncoding.swift`; `Tests/NetworkingTests/BodyEncodingAndResponseDecodingTests.swift`. | Conformant |
| 11. General adapters rerun for every attempt. | `NetworkClient.swift`; `Tests/NetworkingTests/RequestAdapterTests.swift`. | Conformant |
| 12. Authentication adaptation reruns for every authenticated attempt and is the final outgoing mutation stage. | `NetworkClient.swift`; ADR 0006; `Tests/NetworkingTests/AuthenticationTests.swift`; `CONTEXT.md`. | Conformant |
| 13. Authentication replay budget and ordinary retry budget are independent. | `Authentication.swift`, `RetryPolicy.swift`; `Tests/NetworkingTests/AuthenticationTests.swift`, `RetryPolicyTests.swift`. | Conformant |
| 14. Ordinary retry is disabled by default. | `RetryPolicy.swift`; `Tests/NetworkingTests/RetryPolicyTests.swift`. | Conformant |
| 15. Retry happens before final response validation. | `NetworkClient.swift`; `Tests/NetworkingTests/NetworkClientRetryTests.swift`, `ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 16. Validation happens before decoding or download finalization. | `NetworkClient.swift`; `Tests/NetworkingTests/ResponseValidationAndBodyRetentionTests.swift`, `DownloadExecutionTests.swift`. | Conformant |
| 17. Explicit cancellation surfaces as CancellationError. | `NetworkClient.swift`, `NetworkTask.swift`; `Tests/NetworkingTests/NetworkClientProgressTests.swift`. | Conformant |
| 18. A shared NetworkTask is cancelled only through explicit shared cancellation. | `NetworkTask.swift`; `Tests/NetworkingTests/RequestIDAndNetworkTaskTests.swift`, `CombineBridgeTests.swift`. | Conformant |
| 19. Progress is latest-state multicast, not an event-history log. | `NetworkProgress.swift`; `Tests/NetworkingTests/NetworkProgressTests.swift`. | Conformant |
| 20. Successful terminal progress occurs only after the entire logical operation succeeds. | `NetworkTask.swift`; `Tests/NetworkingTests/NetworkClientProgressTests.swift`. | Conformant |
| 21. The response retains the full attempt metrics sequence for a successful multi-attempt operation. | `Response.swift`, `AttemptMetrics.swift`; `Tests/NetworkingTests/AttemptMetricsTests.swift`. | Conformant |
| 22. Downloads are not read entirely into memory merely for validation or authentication. | `ResponseValidationPolicy.swift` file-backed bodies; `Tests/NetworkingTests/DownloadExecutionTests.swift`, `ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 23. Temporary download files from abandoned attempts are always cleaned up. | `DownloadedFile.swift`, `NetworkClient.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift` ("A rejected response never resolves or touches a caller destination"). | Conformant |
| 24. Accessing DownloadedFile.url transfers practical cleanup responsibility to the caller. | `DownloadedFile.swift`; `Tests/NetworkingTests/DownloadExecutionTests.swift`. | Conformant |
| 25. Observers are asynchronous and never awaited by networking execution. | `NetworkEvent.swift`; `Tests/NetworkingTests/NetworkEventTests.swift`. | Conformant |
| 26. Observer delivery is bounded and best-effort, dropping oldest pending events under backpressure. | `NetworkEvent.swift`; ADR 0007; `Tests/NetworkingTests/NetworkEventTests.swift`. | Conformant |
| 27. Logging redacts sensitive headers and query values by default. | `NetworkLogger.swift`; `Tests/NetworkingTests/NetworkLoggerTests.swift`. | Conformant |
| 28. RequestContext diagnostics are opt-in per key. | `RequestContext.swift`, `NetworkLogger.swift`; `Tests/NetworkingTests/RequestContextTests.swift`, `NetworkLoggerTests.swift`. | Conformant |
| 29. No umbrella networking error is introduced to normalize heterogeneous failures. | ADR 0009; library-owned error types; public symbol graph. | Conformant |
| 30. No Equatable or Hashable conformance silently omits semantic state. | `Response.swift`, `BodyRetentionPolicy.swift`, `AttemptMetrics.swift`; `Tests/NetworkingTests/AttemptMetricsTests.swift`, `ResponseValidationAndBodyRetentionTests.swift`. | Conformant |
| 31. No public type is made Sendable through @unchecked Sendable. | Source scan over `Sources/`; strict-concurrency build. | Conformant |
| 32. Future features are not predesigned into 1.0 APIs beyond reasonable extension seams. | Public symbol inventory; ADR 0004; `README.md` capabilities statement. | Conformant |
## 7. Release readiness checklist

Each item records a release prerequisite and the evidence that verifies it. All items below are
verified; none remain open.

| Item | Requirement | Verification | Status |
| --- | --- | --- | --- |
| R1 | MIT license | `LICENSE` contains the MIT text with copyright year 2026; GitHub reports the repository license as MIT. | Verified |
| R2 | Repository posture (specification section 1.2): issues collaborator-only and pull requests collaborator-only | Verified conformant on 2026-10-05: GitHub reports `issueCreationPolicy = COLLABORATORS_ONLY` and `pullRequestCreationPolicy = COLLABORATORS_ONLY`, so only collaborators can open issues and pull requests, matching the specification. Public visibility, issues enabled, pull requests enabled, Discussions disabled, and a single human collaborator with no pending invitations were verified in the same read-only refresh. | Verified |
| R3 | SwiftPM source distribution with exactly the intended products and platform declarations | `Package.swift` declares the two library products `Networking` and `NetworkingTestSupport` and the five platform minimums; no binary or XCFramework pipeline exists. | Verified |
| R4 | README installation and support language | `README.md` documents installation as an explicitly post-release example, states the platform and support policy, and ends with the public-reference notice. | Verified |
| R5 | Agent support deliverables | Section 4 above. | Verified |
| R6 | Tag and release prerequisites | No `1.0.0` tag and no GitHub Release exist locally or on the remote. The steps below are documented but deliberately not executed. | Verified |
| R7 | Release-candidate repository state | The working tree contains only the authorized Issue 28 changes: this document, the documentation validation tooling, the CI documentation job, documentation pointers, and the evidenced `NetworkLogger` warning fix. A clean committed release HEAD is a maintainer step after review, commit, and merge, and every required GitHub CI job must pass on that final `main` commit before tagging; see "Remaining release actions". | Verified in the final audit record |
| R8 | Validation evidence | Documentation gate, repository validation (`make all`), all five platform compilations, whitespace and diff check, and ship review recorded in the final audit record below. The ship review's automated semantic pass covers tracked changes only; the two untracked Issue 28 files are covered by direct review and by the documentation gate. | Verified in the final audit record |
| R9 | Post-1.0 follow-ups recorded | Section 8 below. | Verified |

### 7.1 Remaining release actions

1. Review, commit, and merge the Issue 28 changes so that `main` is the audited release candidate.
2. Wait for every required GitHub CI job on that final reviewed `main` commit to pass; the tag
   must not be created while any required job is failing or still running.
3. Confirm the final state on `main` after CI is green: `git status` clean, `HEAD` equal to the
   reviewed commit, and no uncommitted residue.
4. Tag and release after the CI pass and the final state confirmation:
   `git tag -a 1.0.0 -m "Networking 1.0.0"`, `git push origin 1.0.0`, then
   `gh release create 1.0.0 --title "Networking 1.0.0" --generate-notes`.
5. Close tracking issue 28 once the tag and release exist.

## 8. Post-1.0 follow-ups

| Id | Follow-up | Source | Why it is deferred |
| --- | --- | --- | --- |
| F1 | Add public API compatibility or baseline tooling to CI so unintended SemVer-breaking changes are detected. | Specification section 50 | The specification states this should exist after 1.0 and that API evolution remains intentionally flexible before 1.0. Adding baseline machinery now would lock the surface before the release that defines it. |
| F2 | Remove the visionOS SnapshotTesting exclusion once the released upstream `swift-snapshot-testing` dependency supports visionOS. | Specification section 43 | The restriction exists because of the upstream dependency, not this library. `Networking` and every `NetworkingTestSupport` feature that does not depend on SnapshotTesting already support visionOS. |
| F3 | Close tracking issue 28 and, if desired, open a follow-up issue for F1. | Repository workflow | Issue closure belongs to the maintainer release step; this audit does not mutate GitHub state. |
## 9. Audit verification record

Recorded on 2026-10-04 and refreshed on 2026-10-05 from the final working tree based on commit
`908a8c3`, before any review, commit, or merge. Toolchain: Xcode 27.0 (27A266a) with
Swift 6.4.

Final-state pass: the documentation check, repository validation, platform compiles, whitespace
check, ship review, concurrency scan, and live GitHub posture queries below were re-run on this
frozen tree at the end of the audit, with the repository validation executed last so that its
recorded worktree fingerprint covers the final content of every changed file. These results are
local execution evidence: they were produced on this working tree and are not versioned
artifacts. This record's durable material is the versioned repository content: the committed
documentation, tooling, and CI configuration, together with the GitHub record kept on pull
request 52. The automated review and the required checks on that pull request and on the final
reviewed `main` commit are a prospective release gate rather than completed evidence here, so
the `1.0.0` tag must not be created until every required check is green. The GitHub posture queries
were refreshed on 2026-10-05 after the owner set both creation policies to collaborator-only,
which closed the last open conformance item. The standalone `make format` measurement,
the from-scratch warning build, and the TestSupport live-network scan are
carried from the same session and were not repeated, because they cover files unchanged since
those runs.

| Check | Command | Result |
| --- | --- | --- |
| Documentation catalogs | `make docs-check` | Passed. Public symbol graphs were emitted for both library targets, both DocC catalogs converted with warnings treated as errors, and all 13 required guide topics plus both catalog landing pages were present. |
| Repository validation | Repository validation profile `all`, which runs `make all` | Passed: lint, build, and all tests succeeded (419 tests: 332 in `Tests/NetworkingTests` and 87 in `Tests/NetworkingTestSupportTests`). Local execution evidence on the final working tree, not a versioned artifact; see the note above. |
| Formatting | `make format` | SwiftFormat reformatted 0 of 84 files and skipped 15; no formatting change was needed. |
| Lint | `make lint` | `git diff --check` clean; SwiftLint reported 52 non-serious, pre-existing style warnings and 0 serious violations. |
| Platform compiles | `make platform-build PLATFORM=...` for iOS, macOS, tvOS, watchOS, and visionOS | All five reported `BUILD SUCCEEDED`, including visionOS without the SnapshotTesting integration. |
| Warning-free build | `swift build --scratch-path .build/warning-audit-2` | A from-scratch build of 450 tasks completed with 0 warnings and 0 errors, confirming the diagnostic fix below. |
| Unchecked-concurrency scan | Repository-wide search over `Sources/` | No occurrences of `@unchecked Sendable`, `nonisolated(unsafe)`, `unsafeBitCast`, `withoutActuallyEscaping`, `@preconcurrency`, `fatalError`, `try!`, or `as!`. |
| TestSupport live-network scan | Repository-wide search over `Sources/NetworkingTestSupport` | `URLSession` appears only in documentation comments and in Foundation metric type names; the mock transport creates no session and never falls through to live networking. |
| Whitespace | `git diff --check` | Clean. |
| Ship review | Repository ship review | Refreshed on 2026-10-05: status ready, validation passed, zero semantic findings across the tracked change set, and no blocking findings. The automated semantic pass reports `SEMANTIC_UNTRACKED_CONTENT_NOT_REVIEWED` and does not inspect untracked files, so `Documentation/Conformance.md` and `Scripts/validate-documentation.sh` were covered by direct review and by the documentation gate instead. |
| GitHub posture | Read-only GitHub GraphQL and REST queries | Refreshed on 2026-10-05: GraphQL `repository` reports `visibility = PUBLIC`, `isPrivate = false`, `hasIssuesEnabled = true`, `hasDiscussionsEnabled = false`, `issueCreationPolicy = COLLABORATORS_ONLY`, and `pullRequestCreationPolicy = COLLABORATORS_ONLY`; REST metadata reports `has_issues = true`, `has_pull_requests = true`, `has_discussions = false`, and `private = false`. All section 1.2 posture checks pass; recorded in the section 1.2 row and checklist item R2. |

### 9.1 Changes made by this audit

| Path | Change |
| --- | --- |
| `Documentation/Conformance.md` | Added. This conformance and release-readiness record. |
| `Scripts/validate-documentation.sh` | Added. Emits public symbol graphs and converts both DocC catalogs with warnings treated as errors, and verifies the required guide topics and both catalog landing pages. |
| `Makefile` | Added the `docs-check` target and its help entry. |
| `.github/workflows/ci.yml` | Added the `documentation` job that runs `make docs-check`. |
| `Documentation/AgentGuide.md` | Documented `make docs-check` in the verified command table and added the conformance record to the synchronization rules. |
| `Documentation/Architecture.md` | Linked this conformance record from the architecture map. |
| `Sources/Networking/NetworkLogger.swift` | Removed an always-succeeding conditional cast in error identity diagnostics; the exact-type check now proves the bridge, so the compiler warning is gone with no behavior change. |

No public API was added, removed, or changed by this audit, and the normative specification was not
modified.
