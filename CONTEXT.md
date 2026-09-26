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
- Body preparation, general adapters, and authentication adaptation rerun for each attempt.
- Authentication replay and ordinary retry have independent budgets.
- Retry happens before final response validation.
- Validation happens before decoding or download finalization.
- Explicit cancellation surfaces as CancellationError.
- One waiter cancelling a shared NetworkTask does not cancel the shared operation.
- Progress is latest-state multicast, not an event-history log.
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

## Public modules

- Networking — production API and implementation.
- NetworkingTestSupport — deterministic mock transport, fixtures, matchers, recording, snapshot support, test dependencies, and event/progress recorders.

## Platform boundary

1.0 supports iOS 27+, macOS 27+, tvOS 27+, watchOS 27+, and visionOS 27+ using Swift tools 6.4 / Swift 6 language mode.

Linux and Windows are unsupported.

## Change discipline

If implementation pressure requires changing a normative invariant or consequential architectural decision, update the specification and add or amend an ADR before merging the behavioral change.
