# ``Networking``

Build typed HTTP requests with Swift concurrency. Begin with a single send, then define reusable endpoints and add the policies or task controls your application needs.

For deterministic transport, matchers, fixtures, recorders, and snapshot strategies, continue to the [NetworkingTestSupport guide](https://github.com/danielbyon/swift-networking/blob/main/Sources/NetworkingTestSupport/NetworkingTestSupport.docc/TestSupport.md).

Networking 1.0 supports buffered response decoding, request-body encoding, uploads, downloads, and the policies described below. It does not provide streaming responses, WebSockets, background transfers, multipart encoding, TLS or custom server-trust configuration, or public production transport injection.

## Learn by task

### Start with a request

@Links(visualStyle: detailedGrid) {
    - <doc:GettingStarted>
    - <doc:EndpointAndRequest>
    - <doc:BodyAndQueryEncoding>
}

### Control execution

@Links(visualStyle: detailedGrid) {
    - <doc:Authentication>
    - <doc:Retries>
    - <doc:Validation>
    - <doc:Redirects>
}

### Transfer and observe

@Links(visualStyle: detailedGrid) {
    - <doc:Uploads>
    - <doc:Downloads>
    - <doc:ProgressAndCancellation>
    - <doc:ObservabilityAndLogging>
}

### Integrate with Combine

@Links(visualStyle: detailedGrid) {
    - <doc:CombineBridges>
}
