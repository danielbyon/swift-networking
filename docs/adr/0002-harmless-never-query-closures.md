# Allow harmless input-derived query closures for Never

## Context

`QueryEncoding<Input>` supports query builders that depend on endpoint input. Swift has no usable
negative generic constraint for excluding `Input == Never`, and a specialized unavailable overload
does not reliably prevent the generic closure factory from being selected. Requiring a dummy input
witness would make ordinary query construction less direct.

This differs from `EndpointRoute`: a route must resolve to a URL before request execution, while an
input-derived query value can safely be absent for a no-input endpoint. ADR 0001's witnessed route
decision remains unchanged.

## Decision

Input-derived `QueryEncoding` factories accept their `@Sendable` builder or selector directly,
without an input witness. A closure-based `QueryEncoding<Never>` may be constructed, including from
generic code. When a no-input `Request` binds an endpoint, it uses only fixed query storage and
treats input-derived query storage as absent. It never invokes the closure or fabricates a `Never`
value.

`QueryEncoding<Never>.items(_:)` and `.codable(_:, configuration:)` remain the canonical fixed
query forms for no-input endpoints. Codable serialization remains deferred until logical-execution
preflight; endpoint encoder adjustments remain owned by the Codable query mechanism.

## Consequences

- Input-bearing query factories use the same direct closure spelling as the normative query spec.
- No-input requests safely ignore input-derived query closures without runtime checks or traps.
- The API does not promise that `QueryEncoding<Never>` is statically limited to `.none` and fixed
  query values.
- `EndpointRoute` retains its witnessed input-derived factories because route resolution has a
  different invariant.
