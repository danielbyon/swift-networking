# Architecture map

This document is a guide to the existing Networking 1.0 design. The normative contract is
[`docs/spec/networking-1.0.md`](../docs/spec/networking-1.0.md); this overview points to its governing
sections and the decisions that explain consequential trade-offs. `CONTEXT.md` defines the shared
domain vocabulary.

## Package boundary

The package provides two products:

- `Networking` contains the application-facing HTTP client, immutable endpoint and request values,
  response and task types, policy values, and lifecycle observation.
- `NetworkingTestSupport` depends on `Networking` and supplies a deterministic mock transport,
  recorders, fixtures, and test dependencies.

Production transport is package-internal. Applications cannot inject an arbitrary `URLSession` or
implement a public transport protocol. The test product constructs clients through its testing
factory, and unmatched mock requests fail without falling back to live networking. See spec §§2–4,
§§15–16, and §41; [ADR 0004](../docs/adr/0004-client-owned-session-and-private-transport.md).

## From contract to response

The conceptual path is:

```text
Endpoint -> Request -> NetworkClient -> NetworkTask -> Response
```

- **Endpoint** is an immutable, reusable HTTP contract: route, method, encoding and decoding,
  authentication requirement, and endpoint policy overrides. Input-derived routes use a witnessed
  construction; see spec §§6–7 and [ADR 0001](../docs/adr/0001-input-witnessed-endpoint-routes.md).
- **Request** binds concrete input and body values to that endpoint and carries invocation-level
  overrides. Reusing a request starts a new logical execution each time.
- **NetworkClient** supplies immutable execution configuration and owns the foreground session.
- **NetworkTask** represents one shared logical execution. It exposes one request identity, current
  progress, a shared terminal value, and explicit shared cancellation.
- **Response** contains the accepted decoded value or owned downloaded file, response metadata, and
  the logical execution's attempt metrics.

The operation kind is selected when constructing the endpoint; data, upload, and download share the
same contract and invocation model. See spec §§3–5, §12, §§14–15, §§26, and §30;
[ADR 0003](../docs/adr/0003-endpoint-contract-and-request-invocation.md).

## Logical execution and attempts

Each `NetworkClient.send` creates one logical execution and `RequestID`. It emits `requestStarted`,
performs preflight, and may start numbered transport attempts; preflight failures are not attempts.
An accepted response is validated before decoding or download finalization, and successful terminal
progress follows completion of the full execution. Per-attempt preparation, adaptation, replay, and
retry ordering and budgets are defined in spec §§14, 19–24, and §52; see also
[ADR 0005](../docs/adr/0005-application-owned-credentials-and-explicit-auth.md) and
[ADR 0006](../docs/adr/0006-logical-execution-replay-and-cancellation.md).

## Ownership, concurrency, and cancellation

`Endpoint`, `Request`, and client configuration are immutable. A `NetworkClient` owns one foreground
`URLSession`; active executions can outlive the client. Public concurrency contracts use `Sendable`
without `@unchecked Sendable`. See spec §§5, 12, and 15–16; [ADR 0004](../docs/adr/0004-client-owned-session-and-private-transport.md).

`NetworkTask` shares one terminal result and cancellation across its value awaiters. Canceling a
waiter stops only that wait; `NetworkTask.cancel()` cancels the shared execution. See spec §§30–31
and §39; [ADR 0006](../docs/adr/0006-logical-execution-replay-and-cancellation.md).

The cold `NetworkClient.publisher(for:)` bridge owns one task per subscription; the value and
progress publishers observe an existing task. Their cancellation behavior follows these ownership
boundaries. See spec §40 and `CONTEXT.md`.

Progress replays multicast latest state rather than an event history. Successful terminal progress
follows full execution success; failure and cancellation do not synthesize success. See spec §§28–30
and §52; [ADR 0007](../docs/adr/0007-bounded-observers-and-latest-state-progress.md).

Lifecycle observers use independent bounded queues and cannot block request execution or one
another; overflow makes delivery best-effort. See spec §36 and
[ADR 0007](../docs/adr/0007-bounded-observers-and-latest-state-progress.md).

## Policy precedence

Precedence is specific to each policy; higher layers replace lower values where the API defines an
override. The important rules are:

- Headers layer library-inferred, client, endpoint, and request values before general adapters and
  final authentication adaptation. See spec §11 and §§19–20.
- Relative-route query values layer client → endpoint → request. Absolute routes omit client query
  defaults and use the URL's query with endpoint and request values; replacement and repeated-value
  behavior is defined in spec §§6, 8.6, and 12.6. [ADR 0002](../docs/adr/0002-harmless-never-query-closures.md)
  records the no-input query-closure decision.
- Validation inherits from library default → client → endpoint → request. Retry and redirect use
  their documented client/endpoint/request overrides. See spec §§23–24 and §34.
- Request timeout precedence is client → endpoint → request; resource timeout is client-only. See
  spec §18.
- Successful-response body retention and validation-error body retention both follow client →
  endpoint → request. Their defaults are none for successful responses and unlimited for validation
  errors. See spec §25.
- HTTP/3 preference follows client → endpoint → request. See spec §35.
- URL cache and cookie storage are client/session-level settings with no endpoint/request override.
  See spec §§15–17.
- Authentication is endpoint-declared; a client provider does not enable it implicitly, and requests
  have no authentication override. See spec §19 and [ADR 0005](../docs/adr/0005-application-owned-credentials-and-explicit-auth.md).

## Download ownership

Downloads stay file-backed through validation, and only the accepted file reaches the final
destination. `DownloadedFile` automatically cleans an unexposed temporary file until the caller
reads `url` or successfully moves it; practical cleanup then belongs to the caller. A
caller-selected destination is never automatically removed. See spec §§24–25 and §§32–33;
[ADR 0008](../docs/adr/0008-file-backed-download-ownership.md).

## TestSupport seam

`NetworkingTestSupport` drives the normal request, policy, retry, authentication, validation,
progress, cancellation, and download paths through an actor-backed `MockNetworkTransport`. Tests
can inspect transport-ready requests and each actual attempt. Unmatched requests fail with diagnostics
and never reach the network. Its deterministic clocks, jitter, request-ID generators, progress
updates, and recorders exercise production seams without adding production history or transport
injection. See spec §§41–45 and [ADR 0004](../docs/adr/0004-client-owned-session-and-private-transport.md).

## Decision records

- [ADR 0001 — Require an input witness for input-derived routes](../docs/adr/0001-input-witnessed-endpoint-routes.md)
- [ADR 0002 — Allow harmless input-derived query closures for `Never`](../docs/adr/0002-harmless-never-query-closures.md)
- [ADR 0003 — Endpoint contract and request invocation](../docs/adr/0003-endpoint-contract-and-request-invocation.md)
- [ADR 0004 — Client-owned session and private transport](../docs/adr/0004-client-owned-session-and-private-transport.md)
- [ADR 0005 — Application-owned credentials and explicit authentication](../docs/adr/0005-application-owned-credentials-and-explicit-auth.md)
- [ADR 0006 — Logical execution, replay, and cancellation](../docs/adr/0006-logical-execution-replay-and-cancellation.md)
- [ADR 0007 — Bounded observers and latest-state progress](../docs/adr/0007-bounded-observers-and-latest-state-progress.md)
- [ADR 0008 — File-backed download ownership](../docs/adr/0008-file-backed-download-ownership.md)
- [ADR 0009 — Heterogeneous error model](../docs/adr/0009-heterogeneous-error-model.md)

Deferred capabilities remain outside this 1.0 map. See spec §47 for the supported boundary.

[`Documentation/Conformance.md`](Conformance.md) records the section-by-section conformance evidence
and the release checklist for the 1.0 tag.
