# PlatformKit

The platform a build runs on. Part of [Platform](../README.md).

## Purpose

`PlatformKit` holds one enum, `Platform`, for the few decisions an app can't leave to a library (a desktop layout
against a phone layout, a menu that exists only on one system). Everything that talks to the system lives in a
`Platform<Feature>` library instead; see the [library table](../README.md#libraries).

It does not re-export the feature libraries: import each one you use.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Platform.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "PlatformKit", package: "Platform")]),
]
```

```swift
import PlatformKit

if Platform.current.isDesktop {
  // windows, a pointer and a keyboard
}
```

## Main API

- `Platform`: `.macOS`, `.iOS`, `.linux`, `.windows`, `.android` (`String` raw values, `CaseIterable`).
- `Platform.current`: the platform of this build, decided at compile time. visionOS, tvOS and watchOS report `.iOS`.
- `isDesktop`: true for macOS, Linux and Windows.

## Platform notes

Pure Swift with no system calls: it builds everywhere Swift does. The package declares macOS 14 and iOS 17.

## Testing

```bash
swift test --filter PlatformKitTests
```
