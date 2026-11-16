# PlatformPower

The battery, keeping the device awake, and whether someone is using it. Part of [Platform](../README.md).

<!-- platforms: macos ios=partial linux=partial windows=planned android=planned -->

## Purpose

`PlatformPower` replaces the IOKit power APIs on macOS and `UIDevice`'s battery and the idle timer on iOS with one API:
read the internal battery and follow its changes, hold a sleep assertion while the app does long work, and tell
whether the user is at the device (for an app that records or syncs while nobody watches).

It is not a power-management or energy-use API: it doesn't report power draw, thermal state (see
[PlatformSystem](PlatformSystem.md)) or schedule work.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformPower", package: "Platform"),
```

```swift
import PlatformPower

@MainActor final class Exporter {
  private var awake: SleepAssertion?
  private var battery: BatteryObservation?

  func start() {
    awake = SleepAssertion(.idleSleep, reason: "Exporting a video")   // nil when the system refuses
    battery = Battery.observe { battery in
      if let battery, !battery.isCharging, battery.level < 0.1 { /* pause */ }
    }
  }

  func finish() {
    awake?.release()
    battery?.cancel()
  }
}
```

## Main API

All of it is main-actor isolated except the value types.

- `Battery`: `level` (0...1) and `isCharging` (charging, or full and plugged in).
  - `Battery.current`: the internal battery now, `nil` on a device without one (a desktop, a simulator, a VM).
  - `Battery.observe(_:)`: calls the closure on the main actor whenever the battery changes; returns a
    `BatteryObservation` that stops when cancelled (`cancel()`) or released.
- `SleepAssertion(_:reason:)`: keeps the device from sleeping while held; `nil` when the system refuses or has no way
  to. `Kind.idleSleep` keeps the system awake (the display may sleep); `.displaySleep` keeps the display on too.
  `release()`, or releasing the object, lets the device sleep again.
- `UserPresence`: `idle` (seconds since the last keyboard, mouse or trackpad input, nil where unknown), `isLocked`,
  `isAsleep`, and `isAway(after:)` (locked, asleep, or idle longer than the limit; never true where the device can't
  tell).
  - `UserPresence.isSupported`, `UserPresence.current`.
  - `UserPresence.observe(every:_:)`: reports at once, every `interval` seconds (default 1) and on every lock or sleep
    change; returns a `UserPresenceObservation` (`presence`, `cancel()`).

Nothing here leaves the device or needs a permission.

## Backends

| | Battery | SleepAssertion | UserPresence |
|---|---|---|---|
| macOS | IOKit power sources (`IOPSCopyPowerSourcesInfo`) | IOKit power assertion | `CGEventSource` idle time, `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications, `NSWorkspace` sleep notifications |
| iOS / iPadOS | `UIDevice` battery monitoring | `UIApplication.isIdleTimerDisabled` (one switch for the app, on while any assertion holds it) | not supported |
| Linux | `/sys/class/power_supply`, read again every 30 s | a logind inhibitor lock through `systemd-inhibit` (ends when the app quits or crashes) | not supported |
| Windows | `nil` | `nil` | not supported |
| Android | `/sys/class/power_supply` (same code as Linux, untested) | `nil` | not supported |

## Platform notes

- **macOS**: supported.
- **iOS**: battery and sleep assertions; no `UserPresence` (`isSupported` is false).
- **Linux**: builds (the package is built on an Ubuntu VM); no `UserPresence`. `SleepAssertion` needs systemd
  (`systemd-inhibit`); without it the initializer returns `nil`. Battery changes are noticed within 30 s, as sysfs
  has no change notification without udev.
- **Windows**: no backend yet: no battery, no sleep assertion, no presence.
- **Android**: not built or tested yet.

## Testing

```bash
swift test --filter PlatformPowerTests
```

The tests read what the machine has; they don't need a battery.

## Related

- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
