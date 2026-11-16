# PlatformNotifications

Notifications the device shows by itself, with no push service. Part of [Platform](../README.md).

<!-- platforms: macos ios linux=planned windows=planned android=planned -->

## Purpose

`PlatformNotifications` replaces the parts of `UserNotifications` an app needs to tell the user that something it
follows happened: ask for permission at the right moment, post a notification (with a subtitle, a thread, a picture
and info that comes back), and learn which one the user opened.

It is not a push-notification client: nothing goes through a server, and there are no actions, categories or
scheduled triggers.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformNotifications", package: "Platform"),
```

```swift
import PlatformNotifications

// Early at launch, on the main actor (the App's init), so a notification that launched the app arrives:
@MainActor func listenForOpenedNotifications() {
  UserNotifications.onOpen { info in print("opened", info["camera"] ?? "") }
}

// Right before turning on something that notifies (never at launch):
func enableAlerts() async -> Bool {
  guard UserNotifications.isSupported else { return false }
  return await UserNotifications.requestPermission()
}

func notifyMotion() async throws {
  try await UserNotifications.post(
    UserNotification(id: "motion-door", title: "Motion", body: "Front door", thread: "door", info: ["camera": "door"]))
}
```

## Main API

- `UserNotification(id:title:subtitle:body:thread:image:info:)`: posting again with the same `id` replaces the one
  shown; notifications with the same `thread` are grouped; `image` is JPEG data shown with it; `info` comes back to
  `onOpen`.
- `UserNotifications.isSupported`.
- `UserNotifications.permission() async -> NotificationPermission` (`.notAsked`, `.allowed`, `.denied`): without
  asking.
- `UserNotifications.requestPermission() async -> Bool`: asks once (the system shows its prompt only the first time).
- `UserNotifications.post(_:) async throws`: shows the notification now. Works from an app extension too, with the
  app's permission. Throws `UserNotificationError.unsupported` where the platform can't show one.
- `UserNotifications.onOpen(_:)` (main actor): calls the handler with a notification's `info` when the user opens it,
  and shows notifications while the app is in front too (the system hides them otherwise). Set it once, early.

## Platform notes

- **macOS, iOS / iPadOS, visionOS**: `UserNotifications` (`UNUserNotificationCenter`).
- **Linux, Windows, Android**: not yet. `isSupported` is false, `permission()` answers `.denied`, `requestPermission()`
  answers false and `post` throws `unsupported`. The library's history says it hadn't been built on the Linux VM when
  it was added.

## Testing

The library has no test target. Apps can branch on `UserNotifications.isSupported`.

## Related

- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
