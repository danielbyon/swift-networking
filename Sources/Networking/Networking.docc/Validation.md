# Response Validation

Response validation decides whether an HTTP response is acceptable before decoding its body. The default ``ResponseValidationPolicy/successfulStatusCodes`` policy accepts status codes in `200..<300`. Policy precedence runs from client to endpoint to request; each later policy replaces the lower-precedence policy rather than composing with it.

```swift
let endpoint = Endpoint<Never, Never, Data>.data(
    method: .get,
    route: .absolute(URL(string: "https://api.example.com/v1/status")!),
    response: .data
).validationPolicy(.custom { context in
    context.httpResponse.status == .accepted
        ? .accept
        : .reject(reason: "Expected an accepted response")
})
```

The validation closure receives the response, received body representation, request identifier and request context. It returns `.accept` or `.reject(reason:)`; rejection is surfaced as a typed response-validation error. Retry decisions run before validation, so a retryable response may be retried before the validator sees it. For downloads, validation runs before destination resolution and finalization, so rejected data does not become a caller-owned destination file.

Successful-response body retention defaults to none; validation-error body retention defaults to unlimited. Configure these policies independently on the client, endpoint, or request using the same client-to-endpoint-to-request precedence. Retention can affect memory use and diagnostics, so select it according to the operation's needs.
