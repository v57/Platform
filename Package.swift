// swift-tools-version: 6.2
import PackageDescription

// Apple frameworks the apps need, reimplemented behind one API per feature: each library uses the Apple framework on
// Apple platforms and the platform's own on Linux, Windows and Android, so apps import these instead of the framework
// (the v57 rule: apps import only SwiftUI and our kits). One library per feature, `Platform<Feature>`; `PlatformKit`
// re-exports them all.

let library: [SwiftSetting] = [.swiftLanguageMode(.v6)]

var targets: [Target] = [
  // What the device is: its platform, for the few decisions apps can't leave to a library.
  .target(name: "PlatformKit", swiftSettings: library),
  .testTarget(name: "PlatformKitTests", dependencies: ["PlatformKit"], swiftSettings: library),
]
var products: [Product] = [.library(name: "PlatformKit", targets: ["PlatformKit"])]

// Power: the internal battery and sleep assertions (IOKit on macOS, UIDevice/UIApplication on iOS, sysfs and logind's
// systemd-inhibit on Linux).
targets += [
  .target(name: "PlatformPower", swiftSettings: library),
  .testTarget(name: "PlatformPowerTests", dependencies: ["PlatformPower"], swiftSettings: library),
]
products += [.library(name: "PlatformPower", targets: ["PlatformPower"])]

// Media: a player engine (open, transport, rate, volume, audio and subtitle tracks, time and end events) and its
// SwiftUI video view, on AVFoundation on Apple platforms and GStreamer (playbin) on Linux.
targets += [
  .target(name: "PlatformMedia", swiftSettings: library),
  .testTarget(name: "PlatformMediaTests", dependencies: ["PlatformMedia"], swiftSettings: library),
]
products += [.library(name: "PlatformMedia", targets: ["PlatformMedia"])]

// Disk usage: du-style walks that count hard links and APFS clones once (fts and getattrlist on the Mac, glibc's fts
// through CFTS on Linux), and identical files made into clones of one copy (APFS only).
targets += [
  .target(name: "CFTS"),
  .target(
    name: "PlatformDiskUsage", dependencies: [.target(name: "CFTS", condition: .when(platforms: [.linux]))],
    swiftSettings: library),
  .testTarget(name: "PlatformDiskUsageTests", dependencies: ["PlatformDiskUsage"], swiftSettings: library),
]
products += [.library(name: "PlatformDiskUsage", targets: ["PlatformDiskUsage"])]

// Language model: the system's on-device model (Foundation Models on Apple platforms; none on Linux yet, which says so).
targets += [.target(name: "PlatformLanguageModel", swiftSettings: library)]
products += [.library(name: "PlatformLanguageModel", targets: ["PlatformLanguageModel"])]

// Images: an image file's pixel size and its picture scaled down as RGBA (ImageIO on Apple platforms, GdkPixbuf on
// Linux).
targets += [
  .target(name: "PlatformImage", swiftSettings: library),
  .testTarget(name: "PlatformImageTests", dependencies: ["PlatformImage"], swiftSettings: library),
]
products += [.library(name: "PlatformImage", targets: ["PlatformImage"])]

// Broadcast: named messages of a few strings between one user's processes (DistributedNotificationCenter on the Mac,
// Unix datagram sockets in $XDG_RUNTIME_DIR on Linux).
targets += [
  .target(name: "PlatformBroadcast", swiftSettings: library),
  .testTarget(name: "PlatformBroadcastTests", dependencies: ["PlatformBroadcast"], swiftSettings: library),
]
products += [.library(name: "PlatformBroadcast", targets: ["PlatformBroadcast"])]

let package = Package(
  name: "Platform",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: products,
  targets: targets
)

#if os(Linux) || os(Windows)
// Off Apple platforms SwiftUI (PlatformMedia's video view) is v57/SwiftUI: GitHub's main branch, or the checkout next
// to this one with `V57_LOCAL=1`.
package.dependencies.append(
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/SwiftUI.git", branch: "main") : .package(path: "../SwiftUI"))
for target in package.targets where target.name == "PlatformMedia" {
  target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI"))
}
#endif
#if os(Linux)
// GStreamer for PlatformMedia (`apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`, plus
// gstreamer1.0-plugins-good/-bad and gstreamer1.0-libav for the codecs at run time). Declared only here: elsewhere
// SwiftPM would look for it with pkg-config.
package.targets.append(
  .systemLibrary(
    name: "CGStreamer", pkgConfig: "gstreamer-video-1.0",
    providers: [.apt(["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"])]))
for target in package.targets where target.name == "PlatformMedia" {
  target.dependencies.append("CGStreamer")
}
// GdkPixbuf for PlatformImage (`apt install libgdk-pixbuf-2.0-dev`; GTK desktops have its run-time library).
package.targets.append(
  .systemLibrary(name: "CGdkPixbuf", pkgConfig: "gdk-pixbuf-2.0", providers: [.apt(["libgdk-pixbuf-2.0-dev"])]))
for target in package.targets where target.name == "PlatformImage" {
  target.dependencies.append("CGdkPixbuf")
}
#endif
