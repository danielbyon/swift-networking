# Swift Networking project map

- Swift 6.4 SwiftPM library for Apple platforms; normative behavior lives in `docs/spec/networking-1.0.md`.
- Public products/modules are exactly `Networking` and `NetworkingTestSupport`.
- Source map: `Sources/Networking` contains Endpoint, Request, Response, decoding, and client execution; `Sources/NetworkingTestSupport` contains deterministic package-internal transport support; tests are split by those modules.
- Domain model: Endpoint is immutable reusable contract; Request is immutable concrete invocation; NetworkClient is immutable execution environment; NetworkTask is the logical-execution lifecycle seam.
- Durable invariants: same Request may execute repeatedly as independent logical executions; production transport injection is package-internal; NetworkClient owns URLSession; explicit cancellation surfaces CancellationError; no library-authored unchecked concurrency escape hatches; Equatable/Hashable must include all semantic state.
- Before public API, architecture, concurrency, transport, TestSupport, or invariant changes, consult `AGENTS.md`, `CONTEXT.md`, the relevant spec sections, and applicable ADRs.
- Major references: `mem:tech_stack` for versions/dependencies, `mem:conventions` for implementation/documentation patterns, `mem:suggested_commands` for local commands, `mem:task_completion` for release validation.