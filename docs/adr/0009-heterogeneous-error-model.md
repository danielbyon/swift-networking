# Preserve heterogeneous errors

Status: Accepted for Networking 1.0.

## Context

Failures can originate in Foundation transport, Swift encoding and decoding, caller-provided
adapters, authentication providers, cancellation, or Networking itself. Wrapping all of them in one
public `NetworkError` would add a layer without adding useful semantics and would hide the original
error type that callers need to inspect.

## Decision

Preserve native and collaborator errors when they can be propagated directly, including `URLError`,
`EncodingError`, `DecodingError`, custom encoder errors, adapter and authentication-provider errors,
and `CancellationError`. Define a small family of library-owned errors only for failures Networking
creates itself, such as invalid request construction, missing required authentication configuration,
response validation, redirect limits, and download file lifecycle failures. Explicit library
cancellation is normalized to `CancellationError`.

Do not introduce an umbrella `NetworkError` merely to make unrelated failures share one wrapper.

## Consequences

- Callers can catch or inspect the error type from the layer that produced the failure.
- Networking-owned failures remain identifiable without wrapping errors it did not create.
- Cancellation has one documented public error representation.
- The public error surface remains heterogeneous by design; this is a contract, not an omission.

See spec §§38–39, §52, and §53.5.
