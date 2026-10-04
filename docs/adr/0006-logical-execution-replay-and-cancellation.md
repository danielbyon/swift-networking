# Logical execution, replay, and cancellation

Status: Accepted for Networking 1.0.

## Context

One invocation may create multiple transport tasks because authentication recovery or retry asks
for another attempt. Request identity, attempt metrics, body preparation, and cancellation need to
remain coherent across those replays. A waiter observing shared work should not accidentally cancel
other consumers' operation.

## Decision

Each logical execution gets exactly one `RequestID`; attempt numbers identify only actual transport
tasks and increase from one across authentication replays and ordinary retries. Each attempt
prepares its body and reruns general adapters and authentication adaptation. Authentication recovery
has first opportunity to replay and uses a budget independent from the ordinary retry budget. A
`NetworkTask` starts immediately, stores one shared terminal value, and is canceled for all consumers
only by its explicit, idempotent `cancel()` method. Canceling one value waiter cancels only that
wait. Explicit operation cancellation is surfaced as `CancellationError`.

Networking uses URLSession-level timeouts in 1.0; it does not add a separate logical-operation
deadline.

## Consequences

- Request and attempt histories have stable identities through replay.
- Per-attempt work is regenerated instead of accidentally reusing stale adapted state.
- Authentication recovery does not consume ordinary retry slots, and ordinary retry is disabled by
  default.
- Individual observers can stop waiting without canceling shared work.
- A logical timeout would require a separate deadline and cancellation contract, so it remains
  deferred rather than being inferred from transport timeout settings.

See spec §§14, 19, and 22–24, §§30–31, §39, and §§52–53.16.
