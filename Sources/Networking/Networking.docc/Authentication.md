# Authentication

Authentication is supplied by an application conforming to ``AuthenticationProvider``. Configure that provider on `NetworkClient.Configuration`; mark endpoints that require it with `Endpoint.authenticationRequirement(_:)`.

```swift
import HTTPTypes
import Networking

let configuration = NetworkClient.Configuration(baseURL: apiURL)
    .withAuthenticationProvider(credentialProvider)
let client = try NetworkClient(configuration: configuration)

let protectedEndpoint = endpoint.authenticationRequirement(
    .required(maximumReplays: 1)
)
```

`credentialProvider` is an application-owned value conforming to `AuthenticationProvider`. Its `adapt(_:)` method can update the request before each required attempt. The provider can inspect a rejected response in `recover(_:)` and choose `.replay` or `.doNotReplay`.

`HTTPRequest`, used by `AuthenticationProvider.adapt(_:)`, is defined by the `HTTPTypes` module; import `HTTPTypes` when implementing the provider.

Authentication replay has its own maximum replay count and does not consume the retry policy's retry budget. A requested replay starts immediately, prepares the body again, and runs request adapters and authentication adaptation again. Credentials remain application-managed; the client does not persist or refresh them on its own.

An endpoint that requires authentication without a configured provider fails with an authentication configuration error. Leave the requirement at `.none` for public endpoints.
