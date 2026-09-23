# Swift Networking technology

- Swift tools version 6.4; Swift language mode 6.
- Supported platforms: iOS, macOS, tvOS, watchOS, visionOS 27+; Linux and Windows are unsupported.
- Swift Package Manager package named `swift-networking`.
- Production dependencies: Apple `Foundation`, `swift-http-types` `HTTPTypes` and `HTTPTypesFoundation`, dependency floor `from: 1.8.0`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`).
- Repository automation is Make-backed; lint/format bootstrap shared Swift tooling through `Scripts/swift-tools.sh`.
- TestSupport depends on Networking and exposes deterministic package-internal seams rather than public production transport/session injection.