# PlatformSystem

What the device is and how it's doing: its name, model, CPU, memory, storage, heat, CPU load and network kind. Part
of [Platform](../README.md).

## Purpose

`PlatformSystem` replaces the pieces of Mach, `sysctl`, `UIDevice`, `ProcessInfo` and Network.framework that apps use
to describe a device (a device list, a status panel). Every value is read when asked; nothing leaves the device.

It is not a monitoring service: `CPULoad` gives a share between two calls and `NetworkMonitor` the kind of network in
use, not traffic or reachability of a host.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformSystem", package: "Platform"),
```

```swift
import PlatformSystem

@MainActor func describeDevice() -> String {
  let model = SystemInfo.model ?? "unknown model"
  let network = NetworkMonitor.shared.interface?.rawValue ?? "offline"
  return "\(SystemInfo.deviceName), \(model), \(SystemInfo.osVersion), \(network)"
}
```

## Main API

- `SystemInfo` (static members):
  - `deviceName` (main actor): the name the user gave the device. macOS's computer name, iOS's device name, Linux's
    pretty host name from `/etc/machine-info`, else the host name.
  - `hostName`: the host name without its domain.
  - `osVersion`: `26.1` on macOS and iOS, the distribution's `VERSION_ID` from os-release on Linux (`24.04`; the
    kernel's version when there is none), `10.0.26100` on Windows.
  - `model`: `Mac15,9`, `iPhone17,1` (the simulated model in the Simulator), a Linux machine's device-tree or DMI
    product name; `nil` when the system doesn't say.
  - `cpuModel`: the CPU's marketing name, when the system says.
  - `memoryUsed()`: bytes in use (active, wired and compressed pages on Apple platforms; total minus available on
    Linux).
  - `storage()`: free and total bytes of the volume holding the home folder; free includes purgeable space on Apple
    platforms.
  - `thermalState`: a `ThermalState` (`.nominal`, `.fair`, `.serious`, `.critical`).
- `CPULoad()`: `usage()` returns the busy share of all CPUs (0...1) since the previous call, `nil` on the first call.
- `NetworkMonitor.shared` (or `NetworkMonitor()`): `interface` is the `NetworkInterfaceKind` in use (`.wifi`,
  `.cellular`, `.ethernet`, `.other`), `nil` while offline.

## Backends

- **macOS, iOS**: `sysctl`, Mach `host_statistics64` and `host_statistics` (CPU ticks), URL resource values,
  `ProcessInfo.thermalState`, `UIDevice` (iOS), and Network.framework's `NWPathMonitor`.
- **Linux**: `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/sys/class/thermal` (the thermal zones' trip points),
  `/etc/machine-info`, os-release, `statvfs`, and the default route's interface from `/proc/net/route` and
  `/sys/class/net` (read when asked).
- **Windows, Android**: no backend yet. `hostName` and `osVersion` come from `ProcessInfo`; `model`, `cpuModel`,
  `memoryUsed()`, `storage()`, `CPULoad.usage()` and `NetworkMonitor.interface` return `nil`; `thermalState` is
  `.nominal`.

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: builds on the Ubuntu VM. Network.framework is used only where Darwin is, so a Linux build that also has
  v57/SwiftUI's Network stand-in still compiles.
- **Windows, Android**: fallbacks only, as above.

## Testing

```bash
swift test --filter PlatformSystemTests
```
