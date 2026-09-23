# swift-networking 1.0 Specification

Status: Approved and normative for the 1.0 implementation.

## 1. Project Definition

### 1.1 Identity

- Repository: swift-networking
- Swift package: swift-networking
- Production product/module: Networking
- Testing product/module: NetworkingTestSupport
- License: MIT

### 1.2 Repository posture

The repository is publicly visible on GitHub for source visibility and reference.

Public community support is explicitly out of scope.

Repository configuration:

- Issues enabled, collaborator-only.
- Pull requests enabled, collaborator-only.
- Discussions disabled.
- The owner is expected to be the only human collaborator, aside from authorized automation/AI accounts.
- The README must contain a final section stating that the project is published primarily for reference and that public support and contributions are not accepted.

The project follows SemVer after 1.0.0. Public API source compatibility is considered a release contract.

### 1.3 Purpose

The library exists to:

- centralize networking infrastructure shared by the owner's Apple-platform applications;
- reduce application-specific implementation complexity;
- prevent parallel, fragmented abstractions from being rebuilt on top of URLSession;
- provide a small progressive-disclosure API that starts near the complexity of direct URLSession usage but permits deep configuration;
- provide first-class testing infrastructure so applications do not need to invent separate networking mocks.

### 1.4 Supported platforms

1.0 supports only:

- iOS 27+
- macOS 27+
- tvOS 27+
- watchOS 27+
- visionOS 27+

Windows and Linux are explicitly unsupported. Accidental compilation on those platforms creates no compatibility commitment.

### 1.5 Swift baseline

- Swift tools version: 6.4
- Swift 6 language mode.
- Complete strict-concurrency checking.
- Public concurrency-crossing types must be Sendable.
- Library-authored @unchecked Sendable is prohibited.
- nonisolated(unsafe) and equivalent unchecked concurrency escape hatches are prohibited unless the specification is explicitly amended with rationale.

NetworkClient.Configuration does not need to be Sendable if Foundation-owned configuration objects prevent an honest conformance. The constructed runtime objects must satisfy strict-concurrency requirements.

## 2. Dependencies

### 2.1 Production

Required:

- Apple swift-http-types
- Foundation

swift-http-types types are used directly where they already model the HTTP domain correctly. The library must not create redundant wrappers for:

- HTTP methods;
- HTTP fields;
- HTTP responses;
- HTTP statuses.

Third-party dependencies are accepted only when they substantially improve implementation quality or dramatically reduce complexity.

### 2.2 Testing/TestSupport

Approved:

- Point-Free swift-snapshot-testing
- Point-Free swift-custom-dump
- Point-Free swift-clocks when it materially simplifies deterministic clock behavior

Additional dependencies require explicit justification.

SnapshotTesting and CustomDump must not become dependencies of the production Networking product.

## 3. Package Architecture

The package exposes exactly two products in 1.0:

~~~text
Networking
NetworkingTestSupport
~~~

NetworkingTestSupport depends on Networking.

The production implementation should remain one module unless a proven implementation boundary requires otherwise.

The internal transport abstraction used by TestSupport must use Swift package access or another package-internal mechanism. It must not become a public production extensibility point.

## 4. Core Conceptual Model

The central model is:

~~~text
Endpoint + Input + Body
        ↓
     Request
        ↓
  NetworkClient
        ↓
 NetworkTask
        ↓
   Response
~~~

Definitions:

- Endpoint — reusable HTTP contract/template.
- Request — one immutable concrete invocation of an endpoint.
- NetworkClient — immutable execution environment owning one foreground URLSession.
- NetworkTask — shared identity/lifecycle for one logical execution.
- Response<Value> — typed final response.
- Attempt — one actual URLSession transport execution.

An endpoint does not conceptually manufacture requests. Request explicitly binds an endpoint to concrete invocation data.

## 5. Endpoint

### 5.1 Generic shape

~~~swift
Endpoint<Input, Body, Output>
~~~

Constraints:

~~~text
Input: Sendable
Body: Sendable
Output: Sendable
~~~

Additional protocol constraints are imposed only by the selected encoding or decoding strategy.

Examples:

- JSON body requires Body: Encodable & Sendable.
- JSON response requires Output: Decodable & Sendable.
- Raw data does not require Codable.

### 5.2 Never semantics

Never means the corresponding dimension does not exist.

Examples:

~~~swift
Endpoint<Never, Never, HealthStatus>
Endpoint<GetUserInput, Never, User>
~~~

Convenience overloads must remove Never ceremony from ordinary call sites.

### 5.3 Endpoint factories

The unified endpoint abstraction uses operation-specific static factories:

~~~swift
Endpoint<...>.data(...)
Endpoint<...>.upload(...)
Endpoint<..., DownloadedFile>.download(...)
~~~

The internal operation discriminator is not a public enum that consumers are expected to switch over.

The factory must require an explicit HTTP method. There are no implicit GET/POST defaults.

### 5.4 Operation semantics

#### .data

Means:

> The response body is handled in memory and decoded through the endpoint's response strategy.

A .data endpoint may have:

- no body;
- JSON body;
- raw Data;
- custom in-memory encoded body;
- file-backed body.

A .data endpoint with a file-backed body may internally use URLSession upload-task-from-file behavior. That implementation choice is not exposed through the response model.

#### .upload

Means:

> The endpoint explicitly requests upload-task semantics for the request body.

Uploads always require a body contract.

There is no Body == Never upload convenience.

The upload response is handled like a normal in-memory data response and may decode JSON, return raw data, return EmptyResponse, or use a custom decoder.

#### .download

Means:

> The response body is transferred to disk and returns DownloadedFile.

The output is fixed to:

~~~swift
DownloadedFile
~~~

1.0 does not provide arbitrary post-download transformation into another Output.

Downloads may have:

- no request body;
- in-memory request body.

A download with a file-backed request body is unsupported in 1.0. Because the API intentionally avoids another capability generic/body type, this invalid combination is detected during execution preflight and fails with RequestConstructionError before attempt 1.

### 5.5 Endpoint immutability

Endpoint is an immutable value.

Configuration modifiers return derived copies.

Example style:

~~~swift
let endpoint = Endpoint<...>.data(...)
    .authentication(.required())
    .retryPolicy { policy in
        ...
    }
~~~

### 5.6 Endpoint-defined contract

The endpoint owns and freezes:

- HTTP method;
- route definition;
- query encoding contract;
- endpoint headers;
- body encoding contract;
- response decoding contract;
- authentication requirement;
- endpoint policy overrides.

A concrete Request may not redefine:

- method;
- route;
- body encoding;
- response decoding;
- authentication requirement;
- operation kind.

## 6. Routing

### 6.1 Type

Use a public type:

~~~swift
EndpointRoute<Input>
~~~

`Input` is constrained only by `Sendable`. An endpoint owns its route definition; a request cannot
replace it.

Every input-derived `EndpointRoute<Input>` factory requires a concrete `Input` value as a
construction witness. This rule applies to all input-derived route factories, including relative
routes and any future route forms. The witness proves that `Input` has a value; it is not retained
or used to resolve a request.

### 6.2 Relative routes

Relative routes are expressed as structured path components:

~~~swift
EndpointRoute<MyInput>.relative(forInput: exampleInput) { input in
    ["users", input.userID]
}
~~~

Path builder result:

~~~swift
[String]
~~~

The library percent-encodes each component.

There is no already-percent-encoded path escape hatch in 1.0.

Relative paths are structurally appended to the client's base URL. They are not resolved through string concatenation or ambiguous leading-slash rules.

### 6.3 Absolute routes

Absolute routes may dynamically derive a URL:

~~~swift
EndpointRoute<MyInput>.absolute(forInput: exampleInput) { input in
    input.url
}
~~~

The input-derived absolute route factory follows the general witness rule above. This makes an
input-derived route impossible to construct for `Input == Never`, while imposing no additional
conformance on input types. A no-input endpoint uses a fixed absolute URL:

~~~swift
EndpointRoute<Never>.absolute(url)
~~~

The URL may contain its own query parameters and fragment.

Rules:

- scheme must ultimately be HTTP or HTTPS;
- embedded query parameters are preserved;
- embedded query parameters form the lowest-precedence query layer;
- fragments are stripped before transport;
- client default query items do not automatically apply to absolute routes;
- explicitly configured endpoint/request query items may still add or override query values.

This supports fully formed URLs received from previous API responses.

## 7. Base URL

NetworkClient.Configuration.baseURL is optional.

~~~swift
NetworkClient.Configuration(baseURL: URL?)
~~~

If a relative endpoint is executed without a base URL, execution fails with RequestConstructionError.

A configured base URL must:

- use HTTP or HTTPS;
- contain no query;
- contain no fragment.

Invalid structural configuration is rejected when NetworkClient is initialized.

## 8. Query Encoding

### 8.1 Endpoint abstraction

Endpoint query construction uses one coherent abstraction:

~~~swift
QueryEncoding<Input>
~~~

Conceptual factories:

~~~swift
.none
.items { input in [URLQueryItem] }
.codable { input in queryModel }
~~~

An endpoint chooses one endpoint-level query construction mechanism rather than combining several independent query builders.

### 8.2 URLQueryEncoder

The library provides:

~~~swift
URLQueryEncoder
~~~

It is a deliberately limited Codable-to-query serializer, not an arbitrary object serialization language.

Defaults:

- nil optional → omitted
- empty string → preserved as name=
- Bool → true / false
- Date → ISO-8601
- arrays → repeated key
- nested keyed containers → unsupported

Array strategies:

~~~swift
.repeatedKey
.brackets
~~~

Default: repeatedKey.

Bool strategies:

~~~swift
.literal
.numeric
~~~

Default: literal.

Date strategies include at minimum:

~~~swift
.iso8601
.secondsSince1970
.millisecondsSince1970
.custom(...)
~~~

Default: iso8601.

Unsupported nested keyed containers throw a precise URLQueryEncodingError.

### 8.3 Selection from input

Codable query encoding may select a subvalue:

~~~swift
.codable { input in
    input.filters
}
~~~

Path parameters and query parameters therefore do not need to be encoded from the same model.

### 8.4 Determinism

Codable query output must be deterministic.

Rules:

- encoded keys use deterministic lexical ordering;
- array element order is preserved;
- manually supplied [URLQueryItem] preserves caller order.

### 8.5 Encoder configuration

NetworkClient.Configuration defines client-wide query-encoder defaults.

Endpoint query configuration may layer adjustments on top.

A fresh query encoder is instantiated per logical execution.

### 8.6 Query merge precedence

For relative routes:

~~~text
client defaults
→ endpoint query
→ request query
~~~

For absolute routes:

~~~text
embedded absolute-URL query
→ endpoint query
→ request query
~~~

Client default query items are omitted for absolute routes.

Collision rule:

- higher-precedence layer removes lower-layer occurrences of the same key;
- repeated values within a single layer are preserved intentionally.

Final order:

1. surviving lowest-precedence values;
2. endpoint values;
3. request values.

## 9. Body Encoding

### 9.1 Type

~~~swift
BodyEncoding<Body>
~~~

Built-in forms:

~~~swift
.json(...)
.data(...)
.file(...)
.custom(...)
~~~

### 9.2 JSON

JSON encoding:

- uses a fresh library-owned JSONEncoder per encode operation;
- applies client configuration first;
- applies endpoint configuration second;
- defaults content type to application/json;
- permits explicit media-type override.

Encoder instances are never injected or shared.

### 9.3 Raw data

For Body == Data:

~~~swift
.data(contentType: ...)
~~~

No custom encoder is required.

### 9.4 File bodies

For Body == URL:

~~~swift
.file(contentType: ...)
~~~

The library does not infer MIME type from the filename.

The source file:

- must remain available and stable for the lifetime of the operation;
- is verified as readable before every actual upload attempt;
- is not copied into library-owned storage by default.

Missing/unreadable files fail before the corresponding URLSession attempt begins.

### 9.5 Custom encoding

Custom encoders produce replayable in-memory Data.

They are synchronous throwing operations.

For the same immutable body value, a custom encoder is contractually expected to produce semantically equivalent bytes and avoid attempt-dependent side effects.

Streaming/non-replayable body behavior is not part of this abstraction.

### 9.6 Replayability

1.0 built-in bodies are replayable.

Replayability is inferred by the library; clients do not normally specify it.

Future streaming bodies may introduce non-replayable capabilities without changing the 1.0 invariant.

### 9.7 Per-attempt encoding

Body serialization happens independently for each transport attempt.

The original immutable body value is retained by Request.

This supports retries, auth replay, fresh encoder instances, and per-attempt signing.

Encoding failures happen before a URLSession attempt and therefore do not create an attempt number/metrics record.

Native/custom encoder errors propagate unchanged.

## 10. Response Decoding

### 10.1 Type

~~~swift
ResponseDecoding<Output>
~~~

Built-in strategies:

~~~swift
.json(...)
.data
.empty(...)
.custom(...)
~~~

Download endpoints use DownloadedFile and do not use this decoder abstraction.

### 10.2 JSON

JSON decoding:

- uses a fresh library-owned JSONDecoder per decode;
- applies client configuration first;
- applies endpoint configuration second.

JSON decoding does not require a JSON-compatible Content-Type by default.

The .json() response strategy infers Accept: application/json unless overridden.

A custom JSON-compatible Accept, such as a vendor media type, may be configured independently of decoding behavior.

### 10.3 Raw data

For Output == Data use response: .data.

### 10.4 Empty responses

Use EmptyResponse.

Conformances:

- Sendable
- Equatable
- Hashable
- Codable

It has a public zero-argument initializer.

Response strategy: .empty().

Policy:

~~~swift
EmptyResponseBodyPolicy.ignore
EmptyResponseBodyPolicy.requireEmpty
~~~

Default: ignore.

Under ignore, validation happens normally and the decoder returns EmptyResponse regardless of received body bytes.

### 10.5 Custom decoding

Signature:

~~~swift
@Sendable (Data, HTTPResponse) throws -> Output
~~~

Custom decoding is synchronous and does not perform arbitrary async work.

Native/custom decoding errors propagate unchanged.

## 11. Header Semantics

Precedence:

~~~text
library-inferred defaults
→ client default headers
→ endpoint headers
→ request headers
→ general request adapters
→ authentication
~~~

Examples of library-inferred defaults:

- JSON Accept;
- JSON Content-Type.

Explicit higher-precedence values win.

Swift HTTP Types semantics must be preserved for fields that legitimately support multiple values. The implementation must not collapse headers into [String: String].

The .header(name, value) convenience means set/replace according to normal precedence.

Consumers needing intentional repeated field values use HTTPFields directly.

1.0 does not add special validation or synthesis logic around Content-Length.

Transport-controlled headers are ultimately subject to Foundation/URLSession wire behavior.

## 12. Request

### 12.1 Shape

After construction, input/body generic information is erased:

~~~swift
Request<Output>
~~~

### 12.2 Canonical construction

Bodyful:

~~~swift
Request(
    endpoint: endpoint,
    input: input,
    body: body
)
~~~

Bodyless:

~~~swift
Request(
    endpoint: endpoint,
    input: input
)
~~~

No-input/bodyless:

~~~swift
Request(endpoint: endpoint)
~~~

Downloads default to a temporary destination unless another destination is supplied.

### 12.3 Construction semantics

Request.init is nonthrowing.

At initialization it:

- captures invocation-specific endpoint values;
- resolves all nonthrowing input-dependent builders;
- captures deferred deterministic serialization recipes where a later operation may fail;
- discards the original input where no deferred operation needs it.

Potentially failing operations such as Codable query serialization occur during execution preflight.

Executing the same immutable Request multiple times represents independent logical executions with independent request IDs.

### 12.4 Builder purity

Endpoint route/header/explicit-query builders are @Sendable and nonthrowing.

They are expected to behave deterministically with respect to captured immutable state.

### 12.5 Request modifiers

Immutable derived-copy modifiers include appropriate forms of:

~~~swift
.headers(...)
.header(...)
.queryItems(...)
.requestTimeout(...)
.retryPolicy { ... }
.validationPolicy(...)
.redirectPolicy(...)
.cachePolicy(...)
.assumesHTTP3Capable(...)
.context(..., value: ...)
~~~

Additional body-retention modifiers are also permitted.

There is no request .body(...) modifier.

There is no request authentication override.

There is no request response-decoder override.

### 12.6 Query override

Request query items merge by key and override lower-precedence occurrences.

There is no full arbitrary query-replacement API in 1.0.

## 13. Request Context

Use RequestContext and RequestContextKey.

Key shape:

~~~swift
public protocol RequestContextKey {
    associatedtype Value: Sendable
}
~~~

Values are optional. Keys do not define environment-style defaults.

Setting the same key again replaces the previous value.

Modifier style:

~~~swift
.context(FeatureKey.self, value: "profile")
~~~

Context propagates unchanged across:

- adapters;
- auth replay;
- ordinary retry;
- response;
- observability;
- TestSupport recording.

### 13.1 Diagnostic context

Context is private from logging/snapshots by default.

Opt-in keys use DiagnosticRequestContextKey with a function conceptually equivalent to:

~~~swift
static func diagnosticDescription(for value: Value) -> String
~~~

Diagnostic output identifies the key by its fully qualified Swift type name unless a future requirement justifies another identifier.

## 14. Request Identity

### 14.1 RequestID

~~~swift
public struct RequestID:
    Hashable,
    Sendable,
    Codable
{
    public let rawValue: UUID
}
~~~

### 14.2 Generator

~~~swift
public protocol RequestIDGenerator: Sendable {
    func generateRequestID() -> RequestID
}
~~~

Default: UUIDRequestIDGenerator.

Generation is synchronous, nonthrowing, exactly once per logical execution, and performed before preflight/adapters/auth/transport.

The library does not enforce request-ID uniqueness. The configured generator owns that responsibility.

Test generators may intentionally repeat IDs.

### 14.3 Attempts

Actual URLSession attempts are numbered 1, 2, 3, ... using UInt.

Auth replays and ordinary retries share one monotonically increasing attempt-number sequence.

Attempt identity is derived from (requestID, attemptNumber). No separate attempt UUID is stored.

## 15. NetworkClient

### 15.1 Type

NetworkClient is a final, internally concurrency-safe Sendable reference type.

It is not an actor.

Request starts are not serialized behind actor isolation.

### 15.2 Configuration

Canonical construction:

~~~swift
let configuration = NetworkClient.Configuration(
    baseURL: baseURL
)

let client = try NetworkClient(
    configuration: configuration
)
~~~

Convenience:

~~~swift
try NetworkClient(baseURL: ...)
~~~

Configuration is a value configured through immutable fluent modifiers rather than one massive initializer.

### 15.3 Validation

NetworkClient.init(configuration:) validates the complete configuration before constructing the client.

Failure type: NetworkClient.ConfigurationError.

Conceptual shape:

~~~swift
struct ConfigurationError: Error, Sendable {
    let failures: [Failure]
}
~~~

All discoverable failures are reported together.

Failure ordering is stable and deterministic.

### 15.4 URLSession ownership

The library:

- owns the full URLSession lifecycle;
- creates exactly one foreground URLSession per client;
- does not permit arbitrary URLSession injection;
- does not expose URLSession configuration templates such as .default/.ephemeral as consumer choices.

Future Foundation capabilities are surfaced intentionally through the library rather than via arbitrary session injection.

Client deinitialization does not cancel in-flight logical operations. Internal execution state retains everything required for active operations to finish.

Background URLSession configuration is unsupported in 1.0.

## 16. Session Configuration

Supported 1.0 client-level controls include:

- optional base URL;
- default headers;
- default static query items;
- JSON encoder configuration;
- JSON decoder configuration;
- URL query encoder defaults;
- retry policy;
- response validation;
- redirect policy;
- URL cache;
- cookie storage;
- request timeout;
- resource timeout;
- waits-for-connectivity;
- expensive network access;
- constrained network access;
- cellular access;
- HTTP/3 preference;
- RequestID generator;
- authentication provider;
- request adapters;
- event observers.

Unsupported/rejected for 1.0 unless later amended:

- arbitrary URLSession injection;
- arbitrary URLSessionConfiguration injection;
- background sessions;
- TLS/server-trust customization;
- client certificate handling;
- Multipath;
- arbitrary protocol classes;
- proxy dictionary configuration;
- discretionary scheduling;
- multipart encoder.

## 17. Cache, Cookies, Credentials

### 17.1 Cache

Expose Foundation cache policy directly: URLRequest.CachePolicy.

Client can supply URLCache?.

Default: nil.

No custom library cache is implemented.

### 17.2 Cookies

Client supplies HTTPCookieStorage?.

Semantics:

- nil → cookies disabled;
- non-nil → cookies enabled using exactly that storage.

Callers may explicitly supply .shared.

Cookie storage is client/session-wide, not endpoint/request configurable.

Default: nil.

### 17.3 URL credentials

The internally created session explicitly disables ambient URL credential storage.

The library does not own or persist application credentials.

## 18. Timeouts

Timeouts are wire/session concerns only.

There is no logical end-to-end operation deadline in 1.0.

Expose request timeout and resource timeout.

Representation: Duration?.

nil preserves Foundation default behavior.

An explicit duration must be greater than zero.

Precedence:

- request timeout: client → endpoint → request;
- resource timeout: client only.

## 19. Authentication

### 19.1 Endpoint contract

Authentication is endpoint-owned:

~~~swift
public enum AuthenticationRequirement:
    Sendable,
    Equatable
{
    case none
    case required(maximumReplays: UInt = 1)
}
~~~

Default: none.

There is no client-level default auth requirement and no request-level auth override.

A client may have an authentication provider configured, but the provider remains dormant for .none endpoints.

### 19.2 Zero replay semantics

.required(maximumReplays: 0) means:

- initial authentication adaptation occurs;
- only one transport attempt occurs from the auth perspective;
- recover(...) is not called;
- ordinary retry remains independent.

### 19.3 Provider

Authentication remains a protocol because it coordinates multiple stateful operations:

~~~swift
public protocol AuthenticationProvider: Sendable {
    func adapt(
        _ context: RequestAdaptationContext
    ) async throws -> HTTPRequest

    func recover(
        _ context: AuthenticationRecoveryContext
    ) async throws -> AuthenticationRecovery
}
~~~

Result:

~~~swift
public enum AuthenticationRecovery: Sendable {
    case replay
    case doNotReplay
}
~~~

The provider:

- owns credentials externally;
- owns refresh behavior;
- owns simultaneous-refresh coalescing;
- decides whether a response is an authentication challenge;
- may return an unchanged request;
- may inspect response/body context;
- never exposes credentials to Networking as a library-owned representation.

Missing provider for .required(...) fails before attempt 1 with AuthenticationConfigurationError.

### 19.4 Replay behavior

Authentication replay:

- has a separate budget from ordinary retries;
- is immediate from Networking's perspective;
- has no retry-backoff delay;
- regenerates the request body;
- reruns all general adapters;
- reruns authentication adaptation;
- increments the global transport attempt number.

Once the auth replay budget is exhausted, recover(...) is no longer called.

## 20. General Request Adapters

Adapters are client-level only.

Protocol:

~~~swift
public protocol RequestAdapter: Sendable {
    func adapt(
        _ context: RequestAdaptationContext
    ) async throws -> HTTPRequest
}
~~~

Public type erasure: AnyRequestAdapter.

AnyRequestAdapter supports wrapping any conformer and closure-backed initialization.

Client configuration accepts concrete adapters directly and erases them internally.

Adapters run in registration order, on every actual transport attempt, after body preparation, and before authentication.

Adapters may modify HTTPRequest.

They may not replace the prepared request body.

Adapter errors fail the logical request immediately and are not ordinary retry candidates.

## 21. Prepared Request Body

Adapters/auth receive a read-only body representation:

~~~swift
PreparedRequestBody
~~~

Conceptual cases:

~~~swift
.none
.data(Data)
.file(URL)
~~~

It is inspection-only.

This permits signing, hashing, telemetry, and auth schemes that depend on body bytes/path.

The body cannot be replaced by an adapter/auth provider.

## 22. Execution Pipeline

For one logical execution:

~~~text
Generate RequestID
→ emit requestStarted
→ perform preflight construction
→ start attempt loop
~~~

Each actual transport attempt follows:

~~~text
prepare body for attempt
→ run ordered general adapters
→ run authentication adaptation if required
→ assign/increment attempt number
→ emit attemptStarted
→ execute URLSession task
→ capture HTTP response/error + metrics
→ emit transport events
→ authentication recovery decision
→ ordinary retry decision
→ response validation
→ decode response OR finalize download
→ terminal progress
→ produce Response
~~~

Important invariants:

- body preparation happens per attempt;
- adapters rerun per attempt;
- auth adaptation reruns per attempt;
- authentication is the final outgoing mutation stage;
- nothing mutates the outgoing request after auth adaptation;
- auth recovery gets first refusal on eligible responses;
- ordinary retry runs before validation;
- validation runs before decoding;
- decoding/finalization occurs only for the response actually returned;
- pretransport failures do not increment attempt number;
- pretransport failures produce zero AttemptMetrics.

## 23. Retry

### 23.1 Type

RetryPolicy is an immutable value type.

Default maximumRetries = 0.

Ordinary transport budget = 1 initial attempt + maximumRetries.

Authentication replays are additional.

Example:

~~~text
maximumRetries = 2
maximumAuthenticationReplays = 1

maximum possible URLSession tasks = 4
~~~

### 23.2 Configuration

Core policy includes:

- maximumRetries: UInt;
- retryable methods;
- retryable statuses;
- transient transport classification;
- backoff strategy;
- Retry-After policy;
- optional custom decision hook.

Endpoint/request overrides replace the inherited policy as a value.

Modifier closures operate through validated builder/configuration semantics.

### 23.3 Default eligible methods

When retries are enabled:

~~~text
GET
HEAD
OPTIONS
TRACE
PUT
DELETE
~~~

Excluded by default:

~~~text
POST
PATCH
custom methods
~~~

This models HTTP idempotency semantics but does not guarantee application-level retry safety.

### 23.4 Default retryable statuses

~~~text
408
429
500
502
503
504
~~~

The set is publicly inspectable/configurable.

### 23.5 Transport failures

The built-in transient set includes appropriate connectivity failures such as timeout, connection loss, DNS failure, and inability to connect.

It explicitly excludes deterministic/security/cancellation conditions such as explicit cancellation, malformed request, certificate failure, and authentication configuration errors.

The exact set must be public/inspectable rather than hidden behind a magical transient flag.

### 23.6 Nested retry vocabulary

Retry-specific types should be scoped beneath RetryPolicy where practical:

~~~text
RetryPolicy.BackoffStrategy
RetryPolicy.Jitter
RetryPolicy.RetryAfterPolicy
RetryPolicy.Decision
RetryPolicy.Reason
~~~

### 23.7 Backoff strategies

~~~swift
.immediate

.constant(
    Duration,
    jitter: ...
)

.linear(
    initial: Duration,
    increment: Duration,
    maximum: Duration,
    jitter: ...
)

.exponential(
    initial: Duration,
    multiplier: Double = 2,
    maximum: Duration,
    jitter: ...
)
~~~

Linear and exponential require finite maximum delays.

Arithmetic must safely clamp overflow.

Jitter:

~~~swift
.none
.full
~~~

Defaults:

- immediate → none;
- constant → none;
- linear → none;
- exponential → full.

Full jitter selects uniformly within 0...calculatedDelay.

### 23.8 Retry-After

Supported forms:

- delta seconds;
- HTTP date.

Precedence modes:

~~~text
.local
.server
.maximum
~~~

Default: server.

Behavior:

1. compute local backoff and apply local jitter;
2. parse server Retry-After;
3. apply precedence;
4. sleep exact resulting duration.

Server-provided delay is not additionally jittered.

Invalid Retry-After falls back to local backoff.

Past HTTP dates become zero-duration server delay.

Maximum accepted server delay is 60 seconds by default.

Represent the maximum accepted server delay as an optional duration where nil means unlimited.

### 23.9 Custom retry decision

Custom retry logic:

- is synchronous;
- runs after built-in classification;
- receives built-in proposed decision;
- may return use-built-in-decision, retry, or do-not-retry;
- does not determine its own delay;
- cannot inspect response body bytes.

Retry context includes relevant transport information such as method, response/status/headers, transport error, request context, retry count, and attempt information.

retryCount == 0 means evaluating whether to perform the first retry after the initial attempt.

### 23.10 Cancellation

Retry delays use cancellable Swift clock semantics.

Cancellation during backoff prevents the next attempt.

## 24. Response Validation

### 24.1 Policy

ResponseValidationPolicy is an immutable closure-backed value.

Default named policy: successfulStatusCodes accepting 200..<300.

Higher-precedence policies replace lower-precedence policies rather than silently composing.

Precedence:

~~~text
library default
→ client
→ endpoint
→ request
~~~

### 24.2 Context

Validation receives ResponseValidationContext containing:

- HTTPResponse;
- ReceivedResponseBody;
- RequestID;
- RequestContext.

### 24.3 Received body

~~~swift
public enum ReceivedResponseBody: Sendable {
    case data(Data)
    case file(URL)
}
~~~

For data/upload responses use .data; for download use .file.

A file supplied to policy/auth callbacks is read-only, library-owned, valid only for the callback lifetime, not to be moved/deleted, and not guaranteed to remain valid if its URL is retained.

This prevents large downloads from being loaded into RAM merely for policy inspection.

### 24.4 Validation result

~~~swift
ResponseValidationResult.accept
ResponseValidationResult.reject(reason: String? = nil)
~~~

Rejected responses become ResponseValidationError.

Custom validators do not throw arbitrary errors.

### 24.5 Interaction with retry

Retry happens before validation.

Therefore:

- a retryable 503 may retry before default validation rejects it;
- if custom validation accepts 503 but retry policy still considers it retryable, retry wins;
- to immediately return an accepted 503, remove it from retry eligibility.

## 25. Body Retention

Use BodyRetentionPolicy.

Conceptual cases:

~~~swift
.none
.unlimited
.upTo(Int)
~~~

### 25.1 Successful responses

Default: none.

Precedence: client → endpoint → request.

Decoded data/upload responses may optionally retain raw bytes.

Downloads never read the completed file back into memory for successful raw-body retention.

### 25.2 Validation failures

Default: unlimited.

Precedence: client → endpoint → request.

If truncated, truncation is explicit.

### 25.3 Value

RetainedBody contains:

- data: Data;
- originalByteCount: Int64;
- isTruncated: Bool.

Conformances:

- Sendable
- Equatable
- Hashable

All semantic fields participate.

## 26. Response

Core shape:

~~~swift
public struct Response<Value: Sendable>: Sendable {
    public let value: Value
    public let httpResponse: HTTPResponse
    public let requestID: RequestID
    public let attempts: [AttemptMetrics]
    public let retainedBody: RetainedBody?
}
~~~

Downloads always return Response<DownloadedFile> and successful downloads have no retained raw-body duplicate.

### 26.1 Equality and hashing

Conditional structural equality is supported when every semantic constituent supports it.

~~~swift
Response<Value>: Equatable where Value: Equatable
Response<Value>: Hashable where Value: Hashable
~~~

No semantic field may be silently omitted to manufacture equality/hashability.

General rule:

> Public types conform to Equatable/Hashable only when all semantic state can honestly participate.

Closure-bearing semantic types such as Endpoint and Request do not conform in 1.0.

## 27. Attempt Metrics

Every actual URLSession task creates one attempt record.

AttemptMetrics includes:

- RequestID;
- attempt number;
- normalized metrics;
- diagnostic outcome/retry reason;
- optional/raw URLSession task metrics when provided.

All semantic fields, including raw URLSession metrics, participate in Equatable/Hashable when those conformances are provided.

Normalized fields initially cover broadly useful data such as duration, redirect count, request bytes, response bytes, negotiated protocol, and connection reuse/cache information where available.

Raw Foundation metrics remain available for deeper DNS/TLS/etc. inspection.

Metrics should be collected for every request where Foundation makes them available, provided doing so does not introduce material performance cost.

A final successful Response retains metrics for all preceding failed/retried attempts.

Attempt history remains compact and does not retain complete request/response bodies.

## 28. Progress

### 28.1 NetworkProgress

Conceptual fields:

~~~swift
attemptNumber: UInt?

bytesSent: Int64
expectedBytesToSend: Int64?

bytesReceived: Int64
expectedBytesToReceive: Int64?

isComplete: Bool
~~~

Derived convenience values:

~~~swift
uploadFractionCompleted: Double?
downloadFractionCompleted: Double?
~~~

Fractions are clamped to 0...1.

Raw byte counters are never fabricated/clamped.

### 28.2 Initial state

Every NetworkTask begins with an immediately available synthetic initial progress state.

Before attempt 1:

~~~text
attemptNumber = nil
bytesSent = 0
bytesReceived = 0
isComplete = false
~~~

Expected totals may be populated immediately if already known from the prepared request body.

### 28.3 Per-attempt progress

Progress represents the current transport attempt.

On retry/auth replay:

- attempt number increments;
- counters reset;
- a fresh attempt progress state is published.

Historical byte counts are not accumulated into current progress.

### 28.4 Completion semantics

isComplete == true means the entire logical operation succeeded.

It is not set merely because transport byte movement reached 100%.

Examples that do not produce isComplete == true:

- decoding failure;
- validation rejection;
- retry after complete upload;
- auth replay;
- download finalization failure.

On successful logical completion:

1. terminal progress is published;
2. terminal progress is guaranteed not to be displaced;
3. progress sequence finishes;
4. NetworkTask.value becomes available.

On failure/cancellation:

- no synthetic successful terminal progress is published;
- progress sequence simply finishes;
- value carries the failure.

## 29. NetworkProgressSequence

NetworkTask.progress exposes a library-owned concrete async-sequence type: NetworkProgressSequence.

It is not publicly specified as AsyncStream.

Semantics:

- replaying;
- multicast;
- reusable;
- each iterator is an independent subscriber;
- one subscriber does not consume values from another;
- late subscribers immediately receive latest state;
- subscribers joining after success receive terminal state then completion;
- subscribers joining after failure receive sequence completion;
- cancelling one iterator unregisters only that observer.

Per subscriber:

- at most one unseen nonterminal progress update is buffered;
- a newer nonterminal update replaces the unseen previous one;
- successful final progress is never displaced before that subscriber can consume it.

The sequence stores no full progress history.

Implementation mechanism—actors, locks, continuations, AsyncStream, etc.—is explicitly not part of the public contract.

## 30. NetworkTask

~~~swift
public final class NetworkTask<Value: Sendable>: Sendable
~~~

Core API:

~~~swift
public let requestID: RequestID

public var progress: NetworkProgressSequence { get }

public var value: Response<Value> {
    get async throws
}

public func cancel()
~~~

The task starts immediately when created.

### 30.1 Shared value

Multiple tasks may await the same value.

All receive the same stored terminal result.

Late accesses return the already completed result without new network work.

### 30.2 Cancellation ownership

For an explicitly shared NetworkTask:

- cancelling one waiter on .value immediately throws CancellationError for that waiter;
- the underlying network operation continues;
- other waiters continue normally.

Only networkTask.cancel() cancels the shared operation.

cancel() is idempotent.

Calling it after terminal completion is a no-op.

If explicit cancellation wins:

- all current/future value awaiters receive CancellationError;
- progress finishes without successful terminal progress;
- requestCancelled emits once.

Releasing the last external NetworkTask reference does not implicitly cancel the operation.

A retained progress sequence or waiter keeps required internal operation state alive.

## 31. NetworkClient.send

Canonical API:

~~~swift
func send<Output>(
    _ request: Request<Output>
) async throws -> Response<Output>
~~~

Advanced lifecycle API:

~~~swift
func task<Output>(
    for request: Request<Output>
) -> NetworkTask<Output>
~~~

send internally owns its task.

Therefore cancelling the Swift task awaiting client.send(request) cancels that underlying network operation.

This differs intentionally from cancellation of one waiter on an explicitly shared NetworkTask.

Direct endpoint conveniences mirror request construction:

~~~swift
try await client.send(
    endpoint,
    input: input,
    body: body
)
~~~

with constrained shorter overloads for Never.

Invocation-specific advanced customization requires constructing Request explicitly rather than adding an ever-growing send(...) signature.

There is no client.request(for:) API.

## 32. Downloading

### 32.1 Destination

DownloadDestination cases:

~~~swift
.temporary

.file(
    URL,
    collisionPolicy: ...
)

.resolved(
    collisionPolicy: ...,
    @Sendable (HTTPResponse, RequestContext) throws -> URL
)
~~~

Default: temporary.

Destination is request-level execution state, not endpoint contract.

Response-based destination resolution occurs only after validation succeeds.

The resolver does not receive Foundation's temporary URL.

### 32.2 Collision policy

Use explicit names:

~~~swift
DownloadCollisionPolicy.failIfExists
DownloadCollisionPolicy.replaceExisting
~~~

Default: failIfExists.

Replacement is best-effort atomic where the underlying filesystem operation supports it. Cross-volume/filesystem cases prevent a universal atomicity guarantee.

### 32.3 Finalization ordering

Successful download path:

~~~text
transport complete
→ auth decision
→ retry decision
→ validation
→ resolve destination
→ move/adopt file
→ Response<DownloadedFile>
~~~

Retried/rejected responses never touch the caller's final destination.

### 32.4 Failed download responses

If validation rejects a downloaded response:

1. read only up to the configured validation-error retention amount;
2. construct RetainedBody with correct truncation metadata;
3. remove the temporary file;
4. throw ResponseValidationError.

Any abandoned download file from retry, auth replay, validation rejection, cancellation, or other failure must be cleaned up by the library.

## 33. DownloadedFile

~~~swift
public final class DownloadedFile: Sendable
~~~

Core API:

~~~swift
public var url: URL { get }

public func move(
    to destination: URL,
    collisionPolicy: DownloadCollisionPolicy = .failIfExists
) throws

public func remove() throws
~~~

### 33.1 Ownership

Temporary downloaded files are owned by the DownloadedFile object.

Before external access, an unpersisted temporary file may be automatically removed when the final ownership token is released.

Reading downloadedFile.url permanently disables automatic deinit cleanup.

This is intentional: once the caller has obtained the URL, Networking must not later delete a path the caller may be using.

Files downloaded directly to a caller-specified destination are never auto-removed.

### 33.2 Mutation semantics

move(to:) moves the currently owned file, updates the object's URL, disables automatic cleanup, obeys collision policy, and may be called repeatedly.

remove() is idempotent for an already-absent file unless another unrelated filesystem error occurs.

After removal, .url still returns the previous location.

## 34. Redirects

### 34.1 Policy

RedirectPolicy built-ins:

~~~swift
.follow
.reject
.sameOriginOnly
.custom(...)
~~~

Custom redirect decision is synchronous.

Policy precedence: client → endpoint → request.

Higher-precedence policy replaces lower.

Default: follow.

### 34.2 Redirect limit

Default: 10.

Configured as UInt.

0 means follow no redirects.

The budget resets for each new transport attempt.

Exceeding the limit throws RedirectError.tooManyRedirects with appropriate request/response/attempt context.

### 34.3 Rejected redirects

Rejecting a redirect does not automatically throw.

Foundation's existing 3xx response becomes the final response and proceeds through:

~~~text
auth
→ retry
→ validation
→ decoding
~~~

### 34.4 Foundation redirect semantics

When a redirect is followed, Networking accepts Foundation's proposed redirected request semantics, including method/body transformation.

The request-adapter/auth pipeline is not re-entered inside redirect callbacks.

Redirects do not create new transport attempt numbers.

## 35. HTTP/2 and HTTP/3

Networking does not implement separate HTTP/2 or HTTP/3 transports.

URLSession owns protocol negotiation.

1.0:

- works with URLSession's negotiated HTTP protocol behavior;
- captures negotiated protocol through metrics;
- exposes HTTP/3 first-attempt preference through library configuration.

HTTP/3 preference follows client → endpoint → request.

Default preserves normal Foundation behavior.

## 36. Observability

### 36.1 Observer

NetworkEventObserver is a closure-backed Sendable value.

Conceptual initializer:

~~~swift
NetworkEventObserver { event in
    ...
}
~~~

Observer callbacks are synchronous, nonthrowing, and executed asynchronously from the request workflow.

Networking never waits for observers before continuing request execution.

Observers that need expensive asynchronous work must dispatch/enqueue it themselves.

### 36.2 Queue semantics

Each observer owns an independent bounded FIFO queue.

Therefore:

- a slow observer does not block networking;
- a slow observer does not block another observer;
- event submission occurs in registration order;
- observer completion order is not globally ordered.

On overflow, oldest unprocessed observer event is dropped.

There is no synthetic dropped-event diagnostic in 1.0.

Observability is ordered per observer under normal operation, asynchronous, bounded, and best-effort rather than an audit-log guarantee.

Observers are strongly retained for the client's lifetime.

### 36.3 Events

NetworkEvent uses associated payload structs with an Event suffix.

At minimum:

~~~text
requestStarted(RequestStartedEvent)
attemptStarted(AttemptStartedEvent)
responseReceived(ResponseReceivedEvent)
attemptFailed(AttemptFailedEvent)
authenticationReplayScheduled(AuthenticationReplayScheduledEvent)
retryScheduled(RetryScheduledEvent)
redirectDecision(RedirectDecisionEvent)
requestCompleted(RequestCompletedEvent)
requestFailed(RequestFailedEvent)
requestCancelled(RequestCancelledEvent)
~~~

Every logical request emits exactly one terminal event: completed, failed, or cancelled.

Preflight failures emit requestStarted then requestFailed, with no attempt events.

attemptStarted occurs only immediately before a real URLSession task begins.

responseReceived means transport delivered an HTTP response, before auth/retry/validation semantics.

### 36.4 Event data

All events contain request ID, wall-clock timestamp, and request context where applicable.

Attempt events also contain attempt number.

Attempt-scoped events may expose the final adapted HTTPRequest.

RetryScheduledEvent exposes the calculated final delay after jitter/Retry-After resolution.

AuthenticationReplayScheduledEvent has no delay.

RedirectDecisionEvent includes request ID, attempt number, redirect ordinal, redirect HTTP response, proposed HTTP request, follow/reject decision, timestamp, and request context.

Bodies are not automatically carried through the general event model.

## 37. NetworkLogger

Built-in observer: NetworkLogger.

It integrates with Apple's Logger.

The application owns subsystem/category configuration.

NetworkLogger exposes a NetworkEventObserver.

Default logging includes appropriate data such as method, URL shape, request ID, attempt number, HTTP status, duration, byte counts, retry events, auth replay events, and redirect decisions.

### 37.1 Privacy defaults

Sensitive headers are redacted by default, including at least:

- Authorization;
- Cookie;
- Set-Cookie.

Query names may be logged, but all query values are redacted by default.

Bodies are never logged by default.

Opt-in body diagnostics must be explicit, have a configurable byte cap, avoid automatically reading file-backed uploads/downloads, and avoid dumping binary/non-UTF-8 data as text.

Built-in LocalizedError descriptions use equivalent safe query/header redaction defaults even when structured error properties contain the underlying values.

## 38. Errors

The library deliberately uses heterogeneous errors.

There is no umbrella NetworkError.

### 38.1 Native/directly propagated errors

Preserve where appropriate:

- URLError;
- EncodingError;
- DecodingError;
- custom encoder errors;
- request-adapter errors;
- authentication-provider errors;
- CancellationError.

Explicit user/library cancellation is normalized to CancellationError, not exposed inconsistently as URLError.cancelled.

### 38.2 Library-owned errors

At minimum:

~~~text
NetworkClient.ConfigurationError
RequestConstructionError
AuthenticationConfigurationError
ResponseValidationError
RedirectError
DownloadFileError
~~~

TestSupport additionally owns its testing errors.

All library-owned public error types are Sendable.

Equatable/Hashable are provided only when every semantic field can participate honestly.

LocalizedError is provided where useful.

### 38.3 RequestConstructionError

Covers library-owned pretransport failures such as:

- relative route without base URL;
- unsupported URL scheme;
- URL/query composition failure;
- URLQueryEncoder failure;
- unreadable/missing file body;
- unsupported operation/body combination.

Arbitrary body-encoder errors are not wrapped.

Because request ID generation precedes preflight, construction errors include RequestID.

### 38.4 AuthenticationConfigurationError

Used for library-detectable configuration failures such as endpoint requiring auth without an AuthenticationProvider.

Occurs before attempt 1 and includes request ID.

### 38.5 ResponseValidationError

Contains at least:

- HTTPResponse;
- optional RetainedBody;
- RequestID;
- accumulated attempt metrics;
- validation reason where supplied.

### 38.6 RedirectError

Includes at least tooManyRedirects with request ID, configured limit, last response where available, and accumulated attempt information.

### 38.7 DownloadFileError

Represents filesystem finalization/lifecycle failures.

It preserves safe source/destination context and underlying filesystem error where appropriate.

## 39. Cancellation

Networking makes best-effort use of cooperative Swift cancellation across transport, retry sleeps, body preparation where applicable, adapters, and authentication adaptation/recovery.

Cancellation during backoff stops the next attempt.

Cancellation during authentication/adaptation should propagate when the external collaborator cooperates.

Networking cannot guarantee immediate cancellation if client-provided asynchronous code deliberately catches/ignores cancellation. It does not attempt to police or wrap noncompliant external implementations.

## 40. Combine Bridges

Async/async-throws APIs are canonical.

Combine is a thin compatibility layer guarded by canImport(Combine).

### 40.1 Client publisher

client.publisher(for: request) returns conceptually:

~~~swift
AnyPublisher<Response<Output>, Error>
~~~

It is cold.

Each subscription creates a distinct logical execution.

Cancelling that subscription cancels its exclusively owned network operation.

### 40.2 Existing NetworkTask

~~~swift
networkTask.valuePublisher
networkTask.progressPublisher
~~~

Types:

~~~swift
AnyPublisher<Response<Output>, Error>
AnyPublisher<NetworkProgress, Never>
~~~

They bridge the already-existing shared task.

Cancelling one valuePublisher subscriber only unsubscribes that subscriber.

Cancelling a progress subscriber only stops that observation.

NetworkTask.cancel() remains the explicit shared-operation cancellation mechanism.

Late valuePublisher subscribers receive the stored terminal result.

Progress publisher follows the same replay/latest semantics as NetworkProgressSequence.

## 41. NetworkingTestSupport

NetworkingTestSupport is a first-class product, not a minimal mock helper.

Its goal is to let library and application tests exercise production networking behavior without live I/O.

Live-network fallback is prohibited.

An unmatched request never escapes to URLSession.

### 41.1 Mock transport

Public TestSupport type: MockNetworkTransport.

It is stateful and actor-backed.

Production transport abstraction remains package-internal.

Test client creation is exposed only through TestSupport, conceptually:

~~~swift
let transport = MockNetworkTransport()

let client = try NetworkClient.testing(
    configuration: configuration,
    transport: transport,
    dependencies: ...
)
~~~

### 41.2 Stub vocabulary

Core types:

~~~text
MockNetworkTransport
NetworkStub
RequestMatcher
StubResponse
RecordedRequest
~~~

A stub may be consumed once, N times, or always.

Default: once.

If multiple active stubs match, first registered matching stub wins.

An exhausted finite stub is treated as unavailable so later matching stubs may handle the attempt.

Consumption occurs per actual transport attempt, allowing retries/auth replay to naturally consume queued responses.

### 41.3 Stub responses

Support at minimum:

- HTTP response;
- arbitrary failure;
- redirect behavior;
- download behavior.

JSON conveniences default to 200 OK, empty additional headers, and Content-Type: application/json.

### 41.4 Matchers

Composable RequestMatcher supports:

- method;
- full URL/path;
- query;
- headers;
- body bytes;
- semantic JSON body;
- request context;
- attempt number;
- custom @Sendable matching.

Composition: and, or, not.

Matchers inspect the actual transport-ready request, including auth-added headers.

Diagnostic mismatch output applies redaction.

### 41.5 Unmatched requests

Unmatched attempts immediately fail with rich TestSupport diagnostics describing the received request, available stubs, and mismatch reasons.

No live I/O occurs.

### 41.6 Request recording

Every actual transport attempt is recorded by default.

RecordedRequest contains:

- transport-ready HTTPRequest;
- prepared-body diagnostics;
- request ID;
- attempt number;
- request context.

File-backed uploads record URL/metadata by default rather than eagerly reading large contents.

Tests can explicitly inspect file bytes when required.

TestSupport also provides a derived logical-request grouping by request ID.

### 41.7 Verification

Framework-neutral verification methods throw rich errors.

Examples include verifying all expected finite stubs consumed, request ordering, and cancellation propagation.

There is no deinit-driven automatic verification.

### 41.8 Redirect simulation

Redirect behavior can be simulated explicitly as part of one stub/transport attempt.

It exercises redirect policy, redirect limit, and redirect lifecycle events.

Redirects do not automatically consume another stub as a new logical attempt.

### 41.9 Progress

Stubs can define deterministic progress updates for data, upload, and download.

TestSupport provides a normal progress subscriber/recorder that can accumulate full progress history for assertions.

Production NetworkTask itself does not accumulate history.

### 41.10 Cancellation

Mock operations record whether they were cancelled so client tests can assert cancellation propagation.

### 41.11 Synthetic metrics

Mock stubs may provide library-owned normalized attempt metrics.

Raw URLSession metrics are optional.

Most tests do not need to manufacture Foundation metrics.

## 42. JSON Fixtures

JSON fixture support is first-class.

Support:

- explicit bundle resources;
- inline String;
- inline Data;
- Encodable model creation;
- decoding fixture models;
- constructing HTTP stub responses;
- download fixtures;
- semantic request matching;
- canonical JSON snapshots.

### 42.1 Bundle policy

Fixture resource loading always receives an explicit bundle/resource location.

TestSupport must never guess Bundle.main, caller test bundle, or Bundle.module.

Missing-resource diagnostics include enough explicit bundle/resource information to diagnose the failure.

### 42.2 Decoder/encoder configuration

Fixture model decode/encode accepts explicit configuration closures.

It does not attempt to reach inside a NetworkClient and reuse private codec configuration.

### 42.3 JSON equality

Semantic JSON comparison:

- ignores object key ordering;
- preserves array ordering;
- compares decoded numeric values exactly by default.

Custom matchers may implement tolerances.

### 42.4 Snapshots

A SnapshotTesting strategy named .json emits valid pretty-printed JSON with deterministic key ordering.

The library should rely on established library/system capabilities rather than implement an unnecessary custom JSON-key sorter.

swift-custom-dump is used for structured diagnostics/diffs and non-JSON snapshot representations.

## 43. SnapshotTesting Integration

NetworkingTestSupport provides canonical stable snapshot strategies for sanitized forms of attempted/recorded requests, responses, attempt histories, network event sequences, and JSON.

Integration should follow normal SnapshotTesting conventions rather than introducing library-specific assertion wrappers.

Generated/unstable values such as request IDs, timestamps, and generated boundaries are normalized/redacted where appropriate by default, with opt-in exact-value variants where useful.

## 44. Deterministic Test Dependencies

NetworkClient.testing(...) may receive a TestSupport-only dependency bundle such as NetworkTestDependencies for execution concerns intentionally hidden from production configuration.

It may control:

- monotonic retry/test clock;
- wall-clock now;
- jitter randomness.

RequestIDGenerator remains normal public client configuration and is not moved into this test-only bundle.

If swift-clocks is adopted, it should remain TestSupport/test-only unless production implementation materially benefits from it.

TestSupport supplies at least:

~~~text
StaticRequestIDGenerator
SequenceRequestIDGenerator
~~~

Sequence generator failure on exhaustion must be explicit rather than silently recycling identifiers.

## 45. Network Event Recorder

TestSupport provides NetworkEventRecorder.

It participates through a normal NetworkEventObserver, exercising exactly the production asynchronous observer path.

Because request completion does not wait for asynchronous observers, the recorder provides awaitable helpers such as waiting for a request's terminal lifecycle event.

## 46. URLSession Policy Defaults

Where this library has no deliberate architectural reason to differ, Foundation defaults are preserved.

Intentional deviations:

~~~text
URLCache = nil
HTTPCookieStorage = nil
URLCredentialStorage = nil
~~~

Other supported settings default to normal Foundation behavior unless specified otherwise.

The library owns a standard foreground URLSession configuration and explicitly applies the chosen supported policies.

## 47. Unsupported 1.0 Features

Explicitly out of scope:

- WebSockets;
- streaming responses;
- streaming/non-replayable request bodies;
- background transfers;
- multipart form-data encoder;
- TLS/server-trust policy customization;
- client-certificate customization;
- Multipath TCP;
- arbitrary URLSession/URLSessionConfiguration injection;
- explicit client invalidation API;
- custom HTTP/2 or HTTP/3 transport;
- arbitrary post-download decoding pipeline.

The architecture must avoid obvious blockers to adding WebSockets, streaming, and background tasks later, but the 1.0 public API makes no source-level promise that those features will reuse Endpoint<Input, Body, Output> unchanged.

A post-1.0 lifecycle API analogous to invalidateAndCancel() may be considered later.

## 48. Documentation

Every public symbol must have documentation comments.

A DocC catalog must include at least:

1. Getting Started
2. Endpoint and Request model
3. Body/query encoding
4. Authentication
5. Retries
6. Validation
7. Redirects
8. Uploads
9. Downloads
10. Progress and cancellation
11. Observability/logging
12. TestSupport
13. Combine bridges

README structure:

1. library purpose;
2. quick start;
3. major capabilities;
4. installation;
5. documentation link;
6. platform/support policy;
7. final public-reference/no-public-support notice.

## 49. Agent Support

Agent support is a required 1.0 repository deliverable but is not part of the public Networking API contract.

Required:

- root AGENTS.md;
- Documentation/AgentGuide.md;
- normative 1.0 specification;
- architecture documentation;
- ADRs for consequential decisions;
- build/test/lint/format commands;
- issue-driven implementation workflow;
- at least one validated end-to-end coding-agent implementation workflow using gpt-repo-local.

Repository-specific Skills may ship with 1.0 where a repeated workflow has actually been identified.

Skills must not be created merely for ceremony.

AGENTS.md stays operational and concise. Durable rationale belongs in specification/architecture/ADR documents.

## 50. Repository Tooling

Required:

- SwiftFormat
- SwiftLint

Both use committed configuration.

Both run locally via pre-commit workflow and in CI as mandatory checks.

CI additionally validates package build, Swift 6 strict concurrency, unit tests, TestSupport tests, and applicable compilation across all declared Apple platforms.

After 1.0, CI should include public API compatibility/baseline tooling to detect unintended SemVer-breaking changes.

Before 1.0, API evolution remains intentionally flexible.

Releases use SwiftPM source package, Git tags, and GitHub Releases.

No XCFramework/binary-distribution pipeline is required.

## 51. 1.0 Release Success Criteria

1. Data, upload, and download operations are production-usable across the owner's Apple applications.
2. Swift 6 strict concurrency works without consumer-side workarounds.
3. No library-authored unchecked concurrency escape hatch exists.
4. Endpoint/Request APIs provide low-friction simple usage and deep progressive customization.
5. Codable JSON support is first-class while raw/custom escapes remain available.
6. Authentication never owns credentials and supports deterministic refresh/replay semantics.
7. Retry behavior is explicit, bounded, testable, and disabled by default.
8. Validation, redirects, caching, cookies, timeouts, and HTTP/3 preferences have deterministic precedence.
9. NetworkTask progress/cancellation semantics are deterministic and multicast-safe.
10. Downloaded-file ownership and cleanup behavior is explicit.
11. Metrics retain the complete multi-attempt story.
12. Observability cannot delay networking execution.
13. Logging is privacy-safe by default.
14. TestSupport can exercise the full request pipeline without live network I/O.
15. Retry/auth/progress/redirect/cancellation behavior is deterministically testable.
16. Public APIs are documented with DocC.
17. Coding-agent documentation/workflows are present and validated.
18. There is no known architectural blocker to later streaming, WebSocket, or background-transfer support.
19. The public surface is small and coherent enough to honor SemVer after 1.0.0.

## 52. Cross-Cutting Invariants

The following are normative invariants and should be treated as architecture-level constraints during implementation.

1. Endpoint is contract; Request is invocation.
2. Request and Endpoint are immutable values.
3. NetworkClient runtime configuration is immutable.
4. NetworkClient owns URLSession completely.
5. No public production transport injection exists.
6. No live network can escape MockNetworkTransport.
7. One logical execution gets exactly one RequestID.
8. Attempt numbers correspond only to actual URLSession tasks.
9. Attempt numbers start at 1 and increase monotonically across retries and auth replay.
10. Request body is regenerated independently for each attempt.
11. General adapters rerun for every attempt.
12. Authentication adaptation reruns for every authenticated attempt and is the final outgoing mutation stage.
13. Authentication replay budget and ordinary retry budget are independent.
14. Ordinary retry is disabled by default.
15. Retry happens before final response validation.
16. Validation happens before decoding/download finalization.
17. Explicit user cancellation surfaces as CancellationError.
18. A shared NetworkTask is cancelled only through explicit shared cancellation, not one subscriber/waiter cancellation.
19. Progress is latest-state multicast, not an event-history log.
20. Successful terminal progress occurs only after the entire logical operation succeeds.
21. Response retains the full attempt metrics sequence for a successful multi-attempt operation.
22. Downloads are not read entirely into memory merely for validation/auth policies.
23. Temporary download files from abandoned attempts are always cleaned up.
24. Accessing DownloadedFile.url transfers practical cleanup responsibility to the caller.
25. Observers are asynchronous and never awaited by networking execution.
26. Observer delivery is bounded/best-effort and may drop oldest pending events under backpressure.
27. Logging redacts sensitive headers and query values by default.
28. RequestContext diagnostics are opt-in per key.
29. No umbrella networking error is introduced solely to normalize heterogeneous failures.
30. No Equatable/Hashable conformance may silently omit semantic state.
31. No public type is made Sendable through @unchecked Sendable.
32. Future features must not be predesigned into 1.0 APIs beyond preserving reasonable extension seams.

## 53. Rejected Alternatives and Rationale

### 53.1 Three separate endpoint hierarchies

Rejected: DataEndpoint, UploadEndpoint, DownloadEndpoint.

Reason: they duplicate the shared HTTP contract and encourage parallel APIs for headers, auth, validation, retries, routing, and decoding.

Chosen instead: Endpoint<Input, Body, Output> with operation-specific construction.

### 53.2 Operation generic on Endpoint/Request

Rejected: Endpoint<Input, Output, Operation> and Request<Output, Operation>.

Reason: a single NetworkClient.send API plus library-owned internal dispatch removes the nonsensical operation-method combinations that originally motivated the generic.

### 53.3 Endpoint manufactures Request

Rejected as the canonical mental model.

Chosen: Request(endpoint:input:body:).

Reason: Endpoint remains declarative reusable contract; Request explicitly represents invocation.

### 53.4 Inject arbitrary URLSession

Rejected.

Reason: it would make URLSession an escape hatch around the library's configuration and lifecycle model, weakening consistency between applications.

### 53.5 One umbrella NetworkError

Rejected.

Reason: it would unnecessarily wrap URLError, DecodingError, EncodingError, cancellation, and adapter/provider-defined errors.

Chosen: a small family of library-owned errors only for failures created by the library itself.

### 53.6 Library-owned credential values/storage

Rejected.

Reason: AuthenticationProvider owns credential representation, persistence, refresh, and coalescing.

### 53.7 Runtime mutable NetworkClient configuration

Rejected.

Reason: it creates ambiguous "which request observed which configuration?" behavior under concurrency.

### 53.8 Unlimited observer queues

Rejected.

Reason: telemetry must never create unbounded memory growth.

### 53.9 Blocking networking on observer callbacks

Rejected.

Reason: telemetry/logging must not become request latency.

### 53.10 Retaining every progress update

Rejected.

Reason: progress is current state, not an audit trail.

### 53.11 Raw downloaded body duplication

Rejected.

Reason: it defeats download-task memory semantics.

### 53.12 Multipart in 1.0

Rejected.

Reason: useful but separable and not currently required.

### 53.13 General streaming body support

Rejected.

Reason: introduces replayability/lifecycle semantics that belong in the future streaming design.

### 53.14 Background transfers in 1.0

Rejected.

Reason: background URLSession lifecycle semantics deserve a dedicated design rather than accidental partial support.

### 53.15 Public transport protocol

Rejected.

Reason: the transport seam exists for package implementation/TestSupport, not production extensibility.

### 53.16 Logical operation timeout

Rejected.

Reason: timeout semantics remain wire/URLSession-level in 1.0 rather than introducing a second overall deadline system.

### 53.17 Implicit public auth requirement from client configuration

Rejected.

Reason: an endpoint must explicitly declare whether authentication is part of its contract.

### 53.18 Client query defaults on absolute URLs

Rejected.

Reason: fully formed external URLs should not silently inherit unrelated API-client query parameters.

## 54. Implementation Principle

When implementation pressure exposes a conflict between convenience, strict-concurrency correctness, deterministic behavior, explicit ownership, testability, and preserving the endpoint/request conceptual model, the latter five take precedence over local convenience.

Any implementation choice that materially changes one of the normative invariants above requires a specification/ADR update before merging.
