# PlatformBroadcast

Named messages of a few strings between one user's processes on one machine. Part of [Platform](../README.md).

<!-- platforms: macos ios=planned linux windows=planned android=planned -->

## Purpose

`PlatformBroadcast` replaces `DistributedNotificationCenter` for messages between an app and its own helpers: a
command-line tool asking the running app to do something, or a debug hook driven from a shell. A message is a name and
a `[String: String]`, delivered to every process of the same user observing that name.

It is not a network protocol or a reliable queue: nothing crosses machines or users, a message posted while nobody
observes is lost, and there are no replies (answer with a message of another name).

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformBroadcast", package: "Platform"),
```

```swift
import PlatformBroadcast

// In the app: keep the observation for as long as it should listen.
let observation = Broadcast.observe("com.example.myapp.open") { info in
  print("open", info["path"] ?? "")
}

// In a helper tool:
Broadcast.post("com.example.myapp.open", ["path": "~/Projects/MyApp"])
```

## Main API

- `Broadcast.post(_:_:)`: sends `info` to every process observing `name`, at once.
- `Broadcast.observe(_:handler:)`: calls `handler` on the main queue with each message under `name`; returns a
  `Broadcast.Observation` that stops when cancelled (`cancel()`) or released.
- `Broadcast.messages(named:)`: the same as an `AsyncStream<[String: String]>`, observing while it's iterated.
- `Broadcast.objectKey` (`"object"`): on the Mac, the notification's `object` arrives (and is sent) under this key.

## Backends

- **macOS**: `DistributedNotificationCenter`, delivered immediately.
- **Linux**: a Unix datagram socket per observer in `$XDG_RUNTIME_DIR/v57-broadcast/<name>/` (the temporary folder
  when `XDG_RUNTIME_DIR` isn't set). The folders are created owner-only (`0700`). A message reads at most 64 KB.
- **iOS, Windows, Android**: nothing is delivered. `post` does nothing and `observe` returns an observation that never
  fires.

## Platform notes

- **macOS**: any process of the user can post to a name and observe it. Don't send secrets.
- **Linux**: builds on the Ubuntu VM; use it where the session has a runtime directory (systemd's `/run/user/<uid>`).
- **iOS, Windows, Android**: no backend.

## Testing

```bash
swift test --filter PlatformBroadcastTests
```

## Related

- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
