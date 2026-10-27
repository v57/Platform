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

let package = Package(
  name: "Platform",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: products,
  targets: targets
)
