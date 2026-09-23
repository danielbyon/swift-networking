# Require an input witness for input-derived routes

Swift permits `Never` as a `Sendable` generic argument, so a generic `@Sendable (Input) -> URL`
factory also admits a route builder that cannot be called for `Input == Never`. The unavailable
closure-overload approach is not reliable when the generic result is contextually expected as
`EndpointRoute<Never>`; a Swift 6 client typecheck probe selected the generic overload. A marker
protocol avoids that ambiguity but adds a caller-facing constraint that excludes ordinary values
such as `String`.

Input-derived routes therefore require a concrete input value at construction:

~~~swift
EndpointRoute<String>.absolute(forInput: "sample") { input in
    routeURL(for: input)
}
~~~

The witness proves that `Input` has a value, is not retained, and is not used to resolve requests.
`EndpointRoute<Never>` remains the fixed-URL route form. This keeps the existing generic route value
as the endpoint-owned contract, avoids another public route-kind type, and prevents invalid
no-input route state without runtime checks or additional input conformances.

Migration from the uncommitted issue #2 implementation removes `EndpointRouteInput` and its fixture.
Input-derived route calls change from `.absolute { input in ... }` to
`.absolute(forInput: witness) { input in ... }`; fixed `.absolute(URL)` routes and both `Request`
initializers remain unchanged.
