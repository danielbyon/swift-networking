# Swift Networking conventions

- Keep changes narrowly scoped and preserve the existing architecture; do not broaden later-issue behavior.
- Public types and members require human-readable DocC-style documentation. Keep comments current when public behavior changes.
- Use strict Swift 6 Sendable honestly; do not add `@unchecked Sendable`, `nonisolated(unsafe)`, or equivalent escape hatches.
- Preserve immutable value semantics for Endpoint/Request and immutable final Sendable execution-environment semantics for NetworkClient.
- Keep production transport/session seams package-internal; deterministic tests use package-internal TestSupport transport.
- Prefer Swift Testing tests that assert exact behavior and state transitions, including deterministic no-live-network seams.
- Treat `docs/spec/networking-1.0.md` as normative and `CONTEXT.md` as the concise invariant/vocabulary map; add/update ADRs if implementation pressure changes a documented architectural decision.
- Use CodeGraph before grep/read for indexed source questions; use Serena symbolic tools when they provide a precise source/edit operation.
- Follow the repository's issue-tracker and canonical triage-label guidance under `docs/agents/`.