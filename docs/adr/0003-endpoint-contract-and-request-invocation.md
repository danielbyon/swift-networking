# Endpoint contract and request invocation

Status: Accepted for Networking 1.0.

## Context

Networking needs one reusable HTTP contract that supports data, upload, and download operations,
while keeping each concrete invocation explicit and independently repeatable. Separate endpoint
hierarchies would duplicate shared policy and request behavior. The public operation generic was
rejected because operation-specific endpoint construction, one `NetworkClient.send` API, and
library-owned internal dispatch already solve the invalid-combination problem that originally
motivated the generic. Another public generic dimension would add complexity without solving a
remaining problem.

## Decision

`Endpoint<Input, Body, Output>` is the immutable reusable contract. Operation-specific construction
selects data, upload, or download behavior without a public operation generic. `Request` binds
concrete input and body values to an endpoint and carries invocation-level overrides. Requests are
created explicitly from endpoints; a request cannot replace an endpoint-owned route.

## Consequences

- Shared HTTP policy, routing, authentication, and decoding stay on the endpoint contract.
- A request describes one invocation and can be reused to start independent logical executions.
- The client can expose one send path and dispatch operation-specific transport work internally.
- The model avoids parallel endpoint hierarchies and endpoint-manufactured invocation state.

See spec §§3–7, §12, and §§53.1–53.3, especially §53.2.
