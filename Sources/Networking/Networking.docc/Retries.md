# Retries

Requests do not retry by default. Configure a ``RetryPolicy`` on the client, endpoint, or request. Policy precedence runs from client to endpoint to request; each later policy replaces the lower-precedence policy rather than composing with it, so a request-level policy wins.

```swift
let request = Request(endpoint: endpoint)
    .retryPolicy { policy in
        policy.maximumRetries = 3
        policy.backoffStrategy = .exponential(
            initial: .seconds(1),
            multiplier: 2,
            maximum: .seconds(8)
        )
        policy.retryAfterPolicy = .maximum
    }

let response = try await client.send(request)
```

`maximumRetries` counts retries after the first attempt. The built-in decision uses the policy's method, status-code, and URL error-code sets; a custom decision can refine or replace that decision. Backoff can be immediate, constant, linear, or exponential, with the configured jitter strategy.

The default retryable methods are `GET`, `HEAD`, `OPTIONS`, `TRACE`, `PUT`, and `DELETE`; the default retryable response statuses are 408, 429, 500, 502, 503, and 504. These eligibility defaults do not enable retries by themselves: `maximumRetries` defaults to zero. Method eligibility models HTTP idempotency semantics but cannot guarantee application-level safety.

When a response includes `Retry-After`, `retryAfterPolicy` selects the server delay, local backoff, or the maximum of the two. The default is `.server`; `maximumRetryAfterDelay` can bound the accepted server delay and defaults to 60 seconds. Retry decisions occur before response validation, so a response selected for retry is not first surfaced as a validation failure.

Authentication replay is separate from retries. It has an independent replay limit and is performed immediately when the authentication provider requests it; see <doc:Authentication>.
