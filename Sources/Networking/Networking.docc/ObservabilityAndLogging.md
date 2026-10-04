# Observability and Logging

Attach a ``NetworkEventObserver`` through ``NetworkClient/Configuration`` to receive lifecycle and attempt events:

```swift
import Networking
import OSLog

let networkLogger = NetworkLogger(
    logger: Logger(subsystem: "com.example.app", category: "network"),
    configuration: .init(additionalSensitiveHeaders: ["x-api-key"])
)

let configuration = NetworkClient.Configuration()
    .withEventObserver(networkLogger.eventObserver)
let client = try NetworkClient(configuration: configuration)
```

Observer delivery is asynchronous, bounded, and best-effort. The client does not wait for an observer callback; under pressure, events may be dropped rather than delaying a request. Keep callbacks quick and move expensive work elsewhere.

``NetworkLogger`` provides structured logging with sensitive header and query values redacted by default. Add application-specific header names with `NetworkLogger.Configuration`; request-context diagnostics and body logging are opt-in. Body diagnostics can be capped with `.enabled(maximumBytes:)` and default to `.disabled`. Treat any application-added event fields as data that may contain sensitive information.

Events describe the logical request and its attempts. A redirect remains within an attempt, while a retry or authentication replay creates another attempt. See <doc:Retries> and <doc:Redirects> for those policy boundaries.
