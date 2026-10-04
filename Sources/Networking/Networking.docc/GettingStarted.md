# Getting Started

Use `NetworkClient.send(_:)` to execute a typed request. The endpoint below describes an absolute `GET` route and returns the response body as `Data`.

```swift
import Foundation
import Networking

let endpoint = Endpoint<Never, Never, Data>.data(
    method: .get,
    route: .absolute(URL(string: "https://api.example.com/v1/status")!),
    response: .data
)

let client = NetworkClient()
let response = try await client.send(Request(endpoint: endpoint))
let body = response.value
```

`NetworkClient` owns its URL session and production transport. A client can be reused for multiple requests. `Response.value` contains the decoded output; `Response.httpResponse`, `requestID`, and `attempts` provide the response metadata and attempt history.

The async API is canonical. If a caller needs to retain an operation, observe progress, or cancel the shared operation, create a ``NetworkTask`` with ``NetworkClient/task(for:)`` and await its `value`.

## Next steps

- Define a reusable ``Endpoint`` and construct per-call ``Request`` values in <doc:EndpointAndRequest>.
- Select body and query encodings in <doc:BodyAndQueryEncoding>.
- Add retry, validation, authentication, or redirect policies in the policy guides.
