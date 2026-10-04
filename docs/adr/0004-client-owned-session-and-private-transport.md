# Client-owned session and private transport

Status: Accepted for Networking 1.0.

## Context

The client must apply one consistent configuration and lifecycle model to concurrent requests.
Allowing arbitrary `URLSession` injection or a public transport protocol would let applications
bypass those guarantees. Tests still need deterministic transport behavior without exposing that
production seam as an application extension point. Runtime-mutable client configuration was rejected
because concurrent logical executions would make it ambiguous which configuration a request observed:
“which configuration did this request observe?”

## Decision

`NetworkClient` and its runtime configuration are immutable. The client supports concurrent use and
owns exactly one foreground `URLSession` for its lifetime. Networking does not accept arbitrary
session injection. The production transport abstraction remains package-internal.
`NetworkingTestSupport` exposes test-client creation through its own product and routes requests
through `MockNetworkTransport`; unmatched requests fail instead of using live networking.

## Consequences

- Session configuration and lifecycle remain consistent across a client's concurrent executions.
- Active logical operations retain the state they need and are not canceled merely because the
  client is deinitialized.
- Deterministic transport control is available to tests without making production transport
  replaceable by clients of the library.
- Future Foundation session capabilities must be surfaced intentionally through Networking.

See spec §§2–3, §§15–16, §§41, 53.4, 53.7, and 53.15.
