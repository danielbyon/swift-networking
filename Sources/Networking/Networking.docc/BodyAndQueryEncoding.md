# Body and Query Encoding

An endpoint chooses how to encode its body and query. Each body is encoded afresh for every network attempt, so retry and authentication replay use a newly prepared body.

## Request bodies

Use `BodyEncoding.json()` for an `Encodable` body, `BodyEncoding.data()` for bytes, `BodyEncoding.file(contentType:)` for a file URL, or `BodyEncoding.custom(encode:)` for a caller-defined conversion.

```swift
struct CreateWidget: Encodable, Sendable {
    var name: String
}

struct Widget: Decodable, Sendable {
    var id: String
}

let createWidget = Endpoint<Never, CreateWidget, Widget>.data(
    method: .post,
    route: .absolute(URL(string: "https://api.example.com/v1/widgets")!),
    body: .json(),
    response: .json()
)

let request = Request(endpoint: createWidget, body: CreateWidget(name: "Desk"))
```

File bodies must remain readable when an attempt is prepared and when a replay occurs. The library does not infer a media type from a file name; provide `contentType` explicitly.

## Query values

`QueryEncoding.items(_:)` accepts fixed query items or derives them from endpoint input. `QueryEncoding.codable` encodes an `Encodable` value using `URLQueryEncoder`; configure array, Boolean, and date strategies with `URLQueryEncoder.Configuration` when their wire representation matters.

Per-request `queryItems(_:)` adds the final query layer. For the merge order and duplicate-key behavior, see <doc:EndpointAndRequest>.
