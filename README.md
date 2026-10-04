# Swift Networking

Swift Networking is an asynchronous HTTP client library for Apple platforms. It separates reusable endpoint definitions from individual requests and provides typed response decoding, configurable policies, task progress, and deterministic test support.

## Quick start

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
let data = response.value
```

The asynchronous `send` API is the standard entry point. For reusable requests, per-request policies, progress, cancellation, or observation, start with the [Networking DocC guide](Sources/Networking/Networking.docc/Networking.md).

## Capabilities

- Typed endpoints and immutable requests with layered headers and query items.
- JSON, data, file, and custom request-body encoding with typed response decoding.
- Authentication adaptation and recovery, configurable retries, response validation, and redirect policies.
- Upload and download tasks, replaying progress state, and explicit shared-task cancellation.
- Asynchronous best-effort event observation and privacy-safe logging.
- `NetworkingTestSupport` mocks, request matchers, JSON fixtures, recorders, and snapshot strategies.
- Conditional Combine publishers when Combine is available; async APIs remain canonical.

Streaming responses, WebSockets, background transfers, multipart encoding, TLS/server-trust customization, and public production transport injection are not part of the 1.0 API.

## Installation

After version 1.0.0 has been released and its package tag is available, add this dependency to `Package.swift`:

```swift
.package(url: "https://github.com/danielbyon/swift-networking.git", from: "1.0.0")
```

Then add the products your target uses:

```swift
.product(name: "Networking", package: "swift-networking"),
.product(name: "NetworkingTestSupport", package: "swift-networking")
```

This is a post-release installation example. It does not indicate that the 1.0.0 release or tag exists; release and tag work is tracked separately in [issue #28](https://github.com/danielbyon/swift-networking/issues/28).

## Documentation

- [Networking API and guides](Sources/Networking/Networking.docc/Networking.md)
- [NetworkingTestSupport API and guides](Sources/NetworkingTestSupport/NetworkingTestSupport.docc/NetworkingTestSupport.md)

The DocC catalogs are the canonical API documentation. The Networking catalog progresses from a simple request through endpoint construction, policies, task behavior, and observability. The NetworkingTestSupport catalog explains how to exercise that client deterministically.

## Platform support

| Platform | Minimum version |
| --- | ---: |
| iOS | 27+ |
| macOS | 27+ |
| tvOS | 27+ |
| watchOS | 27+ |
| visionOS | 27+ |

Windows and Linux are unsupported. On visionOS, `Networking` and the non-SnapshotTesting parts of `NetworkingTestSupport` are supported. The SnapshotTesting integration is available on iOS, macOS, tvOS, and watchOS, but not visionOS.

## Public reference

This project is published primarily as a source and API reference. Public support and external contributions are not accepted.
