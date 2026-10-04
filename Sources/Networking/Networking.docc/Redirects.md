# Redirects

Redirect handling is controlled per request attempt by ``RedirectPolicy``. The default `.follow` policy follows up to 10 redirects. Use `.reject`, `.sameOriginOnly(maximumRedirects:)`, or `.custom(maximumRedirects:decide:)` when an endpoint needs a narrower rule.

```swift
let request = Request(endpoint: endpoint)
    .redirectPolicy(.sameOriginOnly(maximumRedirects: 5))

let response = try await client.send(request)
```

Each redirect is evaluated within its current attempt. Following a redirect does not start another retry attempt. A rejected redirect is returned as a 3xx response and then passes through the configured retry and response-validation policies.
