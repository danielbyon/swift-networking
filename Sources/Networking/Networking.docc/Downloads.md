# Downloads

Use `Endpoint.download` to receive a ``DownloadedFile`` instead of holding the full response body in memory. A request can select a temporary destination, a fixed file URL, or a destination resolved by a caller closure.

```swift
import Foundation
import Networking

let download = Endpoint<Never, Never, DownloadedFile>.download(
    method: .get,
    route: .absolute(URL(string: "https://api.example.com/v1/archive")!)
)

let request = Request(endpoint: download)
    .downloadDestination(.temporary)
let response = try await client.send(request)
let downloadedFile = response.value
```

The library manages a temporary download until ownership is transferred. Reading `DownloadedFile.url` transfers cleanup responsibility to the caller; after that access, the caller must remove or otherwise manage the file. If a destination is rejected or a temporary result is abandoned before transfer, the library cleans it up.

Response validation runs before destination resolution and finalization. Download retries repeat the operation and do not expose a partially completed destination as a successful result. See <doc:Validation> for validation behavior and <doc:ProgressAndCancellation> for progress and cancellation.
