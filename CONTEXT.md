# Networking domain context

## Purpose

Networking is a Swift 6.4 package for Apple platforms that centralizes reusable URLSession-based HTTP infrastructure. It is intended to reduce application-level networking complexity while preserving progressive disclosure, deterministic behavior, strict-concurrency safety, and first-class testability.

The normative 1.0 contract is docs/spec/networking-1.0.md. This file is a concise vocabulary and invariant map, not a replacement for the specification.

## Core vocabulary

### Endpoint

A reusable HTTP contract/template.

An Endpoint declares method, route, query encoding, headers, request-body encoding, response decoding, authentication requirement, and endpoint policy overrides.

Endpoint is immutable and value-based.

### Endpoint route

An endpoint-owned definition for resolving an invocation's absolute URL. A no-input endpoint has a
fixed route; an input-bearing endpoint may derive its route from the bound input. A Request cannot
replace the endpoint's route.

### Request

A concrete immutable invocation of an Endpoint.

Request binds concrete input/body values and invocation-specific overrides. It erases the Endpoint input/body generic dimensions and is reusable: sending the same Request multiple times creates independent logical executions.

### NetworkClient

The immutable execution environment.

A NetworkClient owns one foreground URLSession and the configured adapters, authentication provider, retry/validation/redirect policies, session settings, observers, and RequestID generator.

### NetworkTask

The shared lifecycle object for one logical execution.

It exposes RequestID, multicast progress, an async throwing value, and explicit shared cancellation.

### NetworkingTestSupport mock transport

`MockNetworkTransport` is the public actor-backed transport test harness. `NetworkStub`,
`RequestMatcher`, and `StubResponse` are immutable values; registration order, finite-use counts,
attempt recordings, and cancellation observations belong to the mock actor. Matchers inspect the
transport-ready request after general adapters and authentication. Unmatched requests fail in the
mock and never reach live networking.

Every actual transport attempt is recorded with its request ID, attempt number, context, and prepared
body representation. File-backed bodies retain URL and size metadata until a matcher or explicit
inspection reads their bytes. Download responses use library-owned temporary files and the normal
validation, finalization, and `DownloadedFile` ownership path. Verification is explicit and checks
finite stub use, recorded attempt order, or observed cancellation.

The `NetworkTransport` protocol and production client transport initializer remain package-only.
Applications construct a test client through `NetworkClient.testing(...)` in
`NetworkingTestSupport`; `Networking` does not expose transport injection.

Deterministic execution controls stay in `NetworkingTestSupport`. `NetworkTestDependencies` supplies
the monotonic retry sleep, wall-clock time, and jitter used by `NetworkClient.testing(...)`.
`StubLatency` suspends a scripted attempt at numbered pause points, and a repeated stub reaches the
same points once per attempt, so tests wait for the occurrence that belongs to the attempt they
coordinate. `StubProgressUpdate` values publish byte-transfer updates through the normal
`NetworkTask.progress` seam, and a stub may carry `NormalizedAttemptMetrics` that every started
attempt prefers over raw task metrics, which mock attempts leave empty; the supplied metrics also
survive scripted failures, so failed-attempt histories and `attemptFailed` events keep reporting
them. `StaticRequestIDGenerator` and `SequenceRequestIDGenerator` assign deterministic logical
identities, and sequence exhaustion is an explicit programming failure rather than identity reuse.
`NetworkProgressRecorder` and `NetworkEventRecorder` retain observation history through the normal
progress sequence and `NetworkEventObserver` seams without adding production history hooks.
The progress recorder subscribes before `startRecording(_:)` returns, so updates the
sequence publishes after the call reach the recording task. Terminal waiters are claimed either
by the terminal event or by cancellation, never both, so a cancelled waiter throws
`CancellationError`; waiting resolves against the first terminal event recorded for a request
identity, so a test that waits more than once must give each execution a distinct identity
through `SequenceRequestIDGenerator`.

A mock attempt commits its progress start before it records the request or consumes the selected
stub, so a rejected start neither records an attempt nor consumes a stub. Redirect proposals stay
inside one transport attempt: they consume no additional stub, keep the attempt number, and use the
same redirect policy decisions, per-attempt limits, and `redirectDecision` events as URLSession
execution. Because every evaluated proposal reports a decision event, a scripted proposal whose
Foundation request has no HTTP representation fails the attempt before the policy evaluates it
instead of continuing without that event.

### JSONFixture

An immutable, validated JSON document for tests. Create one from inline text or bytes, from a
bundle resource with an explicit `Bundle`, or by encoding a model with a caller-configured
`JSONEncoder`. A fixture keeps its original validated bytes for transport stubs, decodes a model
with a caller-configured `JSONDecoder`, and produces request matchers plus in-memory HTTP and
download stub responses that default to `200 OK` with a JSON content type. Bundle loading never
guesses a bundle: the caller supplies the bundle to search, and loading failures name both the
resource and the bundle that was searched.

### Snapshot stability

SnapshotTesting strategies render recorded requests, attempt histories, lifecycle event
sequences, decoded responses, and JSON fixtures from structured CustomDump values instead of
bespoke string renderers. Sanitized is the default: request identities, timestamps, durations,
and generated locations become stable placeholders so equivalent runs produce identical
snapshots. A snapshot that carries several logical requests numbers their identities by first
appearance, so repeated appearances of one identity share an alias while distinct identities
cannot collapse together; a snapshot with a single identity keeps the plain placeholder.
`SnapshotStability.exact` is the explicit opt-in that restores the recorded identities, UTC
ISO-8601 timestamps with fractional seconds plus the lossless reference-date interval, durations,
and paths. Stability never relaxes
privacy: sensitive header and query values stay redacted in both modes, so a test that snapshots
HTTP fields adds the extra field names to the strategies' `additionalSensitiveHeaders` argument
instead of expecting exact mode to reveal them. Free-form diagnostic text is reduced to its
presence, thrown errors are identified by type only, retained response bytes are never rendered,
and file-backed request bodies contribute location and size metadata without their bytes being
read. Snapshotting a `Response<DownloadedFile>` reads the package-internal ownership location,
so it never transfers cleanup ownership to the caller.

### Semantic JSON equality

Every JSON convenience in `NetworkingTestSupport` — `RequestMatcher.jsonBody(_:)` and
`JSONFixture.requestMatcher()` — shares one decoded-equality model: object key order is
insignificant, array order is significant, and numbers compare exactly by normalized spelling
without floating-point tolerance. The `.json` snapshot strategy reuses the same number scanner,
so canonical output keeps each source number's exact spelling, including arbitrary-precision
decimals and arbitrary-size exponents, while Foundation supplies pretty printing and sorted keys.

### Logical execution

One invocation of send or task(for:).

A logical execution receives exactly one RequestID and may contain multiple transport attempts because of authentication replay or ordinary retry.

### Attempt

One actual URLSession transport task.

Attempt numbers start at 1 and increase monotonically across authentication replays and ordinary retries. Preflight failures are not attempts.

### Authentication replay

A transport replay requested by AuthenticationProvider recovery.

Authentication replay has its own endpoint-owned budget and does not consume ordinary retry slots.

### Ordinary retry

A replay governed by RetryPolicy.

Ordinary retry is disabled by default.

### DownloadedFile

A reference-semantic ownership token for one downloaded filesystem resource.

Temporary download ownership and cleanup behavior are part of its public contract. Reading `url`
transfers cleanup responsibility to the caller. A successful finalization or move transfers cleanup
responsibility away from both the old temporary location and the new caller-selected location; a
failed move preserves the current location and its existing cleanup responsibility. `remove()` is
idempotent when the file is absent and permanently disarms cleanup once absence is established.

### RequestContext

Typed, Sendable request metadata that propagates through adapters, authentication, retries, observability, responses, and TestSupport.

Context is not a general dependency-injection environment.

### NetworkLogger

An optional adapter from lifecycle events to an application-supplied Apple Logger. It uses the existing NetworkEventObserver delivery path, sanitizes headers and query values by default, and only renders already-retained response bytes when a finite cap is explicitly configured.

## Operation model

Endpoint has three construction modes:

- data — response bytes are handled in memory and decoded.
- upload — explicitly requests upload-task semantics for the request body; response is still handled in memory.
- download — response is transferred to disk and returns DownloadedFile.

A data endpoint may use a file-backed request body and internally select upload-task-from-file behavior.

A download endpoint with a file-backed request body is unsupported in 1.0 and fails during preflight before attempt 1.

## Execution pipeline

For each transport attempt:

1. Prepare the request body.
2. Run ordered general request adapters.
3. Run authentication adaptation when required.
4. Start the URLSession task and assign the next attempt number.
5. Capture response/error and metrics.
6. Give authentication recovery first opportunity to request replay.
7. Evaluate ordinary retry.
8. Validate the final response.
9. Decode the accepted in-memory response or retain/finalize the accepted download.

Authentication is the final outgoing request mutation stage.

## Cross-cutting invariants

- Endpoint is contract; Request is invocation.
- Endpoint and Request are immutable values.
- NetworkClient runtime configuration is immutable.
- NetworkClient owns URLSession completely.
- Production transport injection is not public API.
- MockNetworkTransport never falls back to live networking.
- One logical execution gets exactly one RequestID.
- Attempt numbers correspond only to actual URLSession tasks.
- Attempt start and `attemptStarted` publication commit together against shared cancellation;
  cancellation that wins first starts no URLSession task.
- Body preparation, general adapters, and authentication adaptation rerun for each attempt.
- Authentication replay and ordinary retry have independent budgets.
- Retry happens before final response validation.
- Validation happens before decoding or download finalization.
- Explicit cancellation surfaces as CancellationError.
- One waiter cancelling a shared NetworkTask does not cancel the shared operation.
- Progress is latest-state multicast, not an event-history log.
- NetworkEvent is bounded best-effort lifecycle history with FIFO submission per observer; registration order governs submission, not callback completion across observers.
- Successful terminal progress occurs only after the entire logical operation succeeds.
- Response retains attempt metrics for the full multi-attempt execution.
- Downloads are not loaded wholly into memory merely for validation or authentication.
- Abandoned download files are cleaned up.
- Reading DownloadedFile.url disables automatic temporary-file cleanup before the URL escapes.
- Successful download finalization and moves permanently disarm cleanup for the old temporary path.
- Caller-selected final destinations are never removed automatically.
- Removing a download disarms cleanup after removal succeeds or the current path is already absent.
- Observers are asynchronous, bounded, best-effort, and never awaited by networking execution.
- Logging redacts sensitive headers and query values by default.
- RequestContext diagnostics are opt-in per key.
- Networking intentionally has heterogeneous errors rather than an umbrella error.
- Equatable/Hashable conformances may not silently omit semantic state.
- Library-authored unchecked concurrency escape hatches are prohibited.
- JSON matching and JSON fixtures share one semantic equality model; numbers compare exactly, never with floating-point tolerance.
- Snapshots sanitize generated identities, timestamps, durations, and generated paths by default; exact rendering is an explicit opt-in that never relaxes header, query, or error redaction.
- Snapshotting a downloaded response is observational and never transfers file cleanup ownership.

## Public modules

- Networking — production API and implementation.
- NetworkingTestSupport — deterministic mock transport, fixtures, matchers, recording, snapshot support, test dependencies, and event/progress recorders.

SnapshotTesting and CustomDump are test-only dependencies: the production Networking target does not
depend on them, and NetworkingTestSupport is the only product that exposes snapshot integration.
The canonical SnapshotTesting integration is available on iOS 27+, macOS 27+, tvOS 27+, and
watchOS 27+ while the released upstream dependency lacks visionOS support. visionOS continues to
support Networking and every NetworkingTestSupport feature that does not depend on SnapshotTesting.
Remove this temporary restriction once a released upstream swift-snapshot-testing version supports
visionOS.

## Platform boundary

1.0 supports iOS 27+, macOS 27+, tvOS 27+, watchOS 27+, and visionOS 27+ using Swift tools 6.4 / Swift 6 language mode.

Linux and Windows are unsupported.

## Change discipline

If implementation pressure requires changing a normative invariant or consequential architectural decision, update the specification and add or amend an ADR before merging the behavioral change.
