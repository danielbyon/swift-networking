# Endpoint and Request

An ``Endpoint`` is a reusable description of an operation: its route, input and body types, response decoding, and endpoint-level defaults. A ``Request`` supplies the input and body for one invocation and carries per-call headers, query items, and policy overrides.

```swift
import Foundation
import Networking

struct SearchInput: Sendable {
    var term: String
}

struct SearchResult: Decodable, Sendable {
    var id: String
}

let search = Endpoint<SearchInput, Never, [SearchResult]>.data(
    method: .get,
    route: .relative(forInput: SearchInput(term: "")) { _ in ["search"] },
    response: .json(),
    query: .items { input in
        [URLQueryItem(name: "q", value: input.term)]
    }
)

let request = Request(endpoint: search, input: SearchInput(term: "swift"))
    .header(.accept, "application/json")
```

The sample uses a relative route, so configure the client with a base URL. The value passed as `inputWitness` to `EndpointRoute.relative(forInput:makePath:)` supplies the generic input type; the route retains the closure, not that witness value.

Requests are immutable values. Modifiers such as `header`, `queryItems`, `retryPolicy`, and `validationPolicy` return a new request, so a base request can be reused safely:

```swift
let jsonRequest = request.header(.accept, "application/json")
let compactRequest = request.queryItems([URLQueryItem(name: "limit", value: "10")])
```

For relative routes, query items merge from client defaults, endpoint encoding, and request modifiers. For absolute routes, query items embedded in the URL replace the client-default layer; endpoint and request items are then applied. Later layers replace earlier values with the same name, while repeated values within one layer remain repeated.

Use the bodyful `Request` initializers when the endpoint declares a body type. The endpoint describes serialization once; each request provides the value for that invocation.
