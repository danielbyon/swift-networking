# Bounded observers and latest-state progress

Status: Accepted for Networking 1.0.

## Context

Lifecycle events and progress help applications observe requests, but an unbounded event or progress
history can retain memory indefinitely. Slow telemetry consumers must not add request latency or
block other consumers.

## Decision

Each event observer receives an independent bounded FIFO queue. Networking does not wait for
callbacks; when a queue overflows, the oldest unprocessed event is dropped. Delivery is best effort,
not an audit log. Production task progress is replaying multicast latest state: each subscriber keeps
at most one unseen nonterminal update, and successful terminal progress cannot be displaced.
Production progress does not retain full history. TestSupport recorders may retain history for
assertions.

## Consequences

- A slow observer cannot block request execution or another observer.
- Event submission order is preserved per observer, while completion order across observers is not
  globally ordered.
- Consumers receive useful current progress without making every byte update durable state.
- Tests that need event or progress history use explicit TestSupport recorders.

See spec §§28–30, §36, §41, §45, and §§53.8–53.10.
