# Uploads

Use `Endpoint.upload` when sending a request body through URL session's upload operation. The body encoding remains explicit, and the endpoint still controls the output decoder.

```swift
import Foundation
import Networking

let upload = Endpoint<Never, URL, Data>.upload(
    method: .post,
    route: .absolute(URL(string: "https://api.example.com/v1/archive")!),
    body: .file(contentType: "application/zip"),
    response: .data
)

let request = Request(endpoint: upload, body: archiveURL)
let response = try await client.send(request)
```

The file URL is the body value. Keep the file available and readable for each attempt because retry or authentication replay prepares the body again. Supply a content type explicitly; file extensions do not select one. Use a data or custom body encoding for in-memory or application-defined uploads.

Upload progress is exposed through the task's progress sequence. See <doc:ProgressAndCancellation> for replay, coalescing, and cancellation behavior.
