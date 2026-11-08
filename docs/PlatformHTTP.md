# PlatformHTTP

An HTTP response body as it arrives, byte by byte or line by line. Part of [Platform](../README.md).

## Purpose

`PlatformHTTP` replaces `URLSession.bytes(for:)`, which Apple's Foundation has and swift-corelibs-foundation (Linux,
Windows) lacks. Use it for server-sent events, streamed JSON lines and long downloads read as they come.

It is not an HTTP client of its own: it sends the `URLRequest` through `URLSession`, with that session's
configuration, and adds no retries, caching rules or authentication.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformHTTP", package: "Platform"),
```

```swift
import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import PlatformHTTP

func streamEvents(from url: URL) async throws {
  let (body, response) = try await HTTPBytes.response(for: URLRequest(url: url))
  guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
  for try await line in body.lines {
    print(line)
  }
}
```

## Main API

- `HTTPBytes.response(for:session:) async throws -> (HTTPBytes, URLResponse)`: sends the request and returns once
  the response's headers are in; the body follows through the sequence. `session` defaults to `.shared`. Cancelling
  the task cancels the request.
- `HTTPBytes`: an `AsyncSequence` of `UInt8`.
- `lines`: an `AsyncThrowingStream<String, any Error>` of the body's lines without their line breaks (`\n`, `\r\n`,
  `\r`).

## Backends

- **macOS, iOS**: `URLSession.bytes(for:)`.
- **Linux, Windows**: a data task on a session with the given session's configuration and a delegate that hands
  over the chunks as they arrive.
- **Android**: the same code as Linux; not built or tested.

## Platform notes

- **macOS, iOS, Linux**: supported.
- **Windows**: builds; the test and its loopback server (Winsock) run there.
- Importing `FoundationNetworking` is needed for `URLRequest` and `URLResponse` off Apple platforms, as with any
  `URLSession` code.

## Testing

```bash
swift test --filter PlatformHTTPTests
```

The tests start a loopback HTTP server of their own; no network is needed.
