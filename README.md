# Platform

Apple frameworks the v57 apps need, reimplemented behind one API per feature. Each `Platform<Feature>` library uses
the Apple framework on Apple platforms and the platform's own elsewhere (Linux, Windows, Android), so apps stay free
of `#if os` and Apple-only imports. `PlatformKit` says which platform a build runs on.

## Libraries

Each library is its own SwiftPM product: `.package(url: "https://github.com/v57/Platform.git", branch: "main")`, then
`.product(name: "<Library>", package: "Platform")`. The package declares macOS 14 and iOS 17; Linux builds use system
libraries (listed on each page), and Linux and Windows builds take v57/SwiftUI from GitHub's `main` (or `../SwiftUI`
with `V57_LOCAL=1`).

| Library | Purpose | Platforms | Import |
|---|---|---|---|
| [PlatformKit](docs/PlatformKit.md) | The platform a build runs on | macOS, iOS, Linux, Windows | `import PlatformKit` |
| [PlatformPower](docs/PlatformPower.md) | Battery, sleep assertions, whether someone uses the device (IOKit, UIDevice) | macOS; iOS and Linux partial (no presence) | `import PlatformPower` |
| [PlatformSystem](docs/PlatformSystem.md) | Device name, model, CPU, memory, storage, heat, CPU load, network kind | macOS, iOS, Linux | `import PlatformSystem` |
| [PlatformMedia](docs/PlatformMedia.md) | Media player and video view, Now Playing (AVFoundation, MediaPlayer) | macOS, iOS, Linux | `import PlatformMedia` |
| [PlatformDiskUsage](docs/PlatformDiskUsage.md) | Disk usage counting hard links and clones once, duplicate files as clones, file access | macOS, iOS; Linux and Windows partial (no clones) | `import PlatformDiskUsage` |
| [PlatformLanguageModel](docs/PlatformLanguageModel.md) | The system's on-device language model (Foundation Models) | macOS 26, iOS 26 | `import PlatformLanguageModel` |
| [PlatformImage](docs/PlatformImage.md) | Image file sizes, thumbnails, PNG and JPEG writing (ImageIO) | macOS, iOS, Linux | `import PlatformImage` |
| [PlatformBroadcast](docs/PlatformBroadcast.md) | Messages between one user's processes (DistributedNotificationCenter) | macOS, Linux | `import PlatformBroadcast` |
| [PlatformHTTP](docs/PlatformHTTP.md) | A response body as it arrives (`URLSession.bytes(for:)`) | macOS, iOS, Linux, Windows | `import PlatformHTTP` |
| [PlatformWeb](docs/PlatformWeb.md) | A web page and its view (WKWebView) | macOS, iOS, Linux | `import PlatformWeb` |
| [PlatformDiscovery](docs/PlatformDiscovery.md) | Browsing and advertising DNS-SD services (dns_sd) | macOS, iOS, Linux | `import PlatformDiscovery` |
| [PlatformCamera](docs/PlatformCamera.md) | Camera capture, H.264/HEVC encoding, fragmented MP4, live view, motion (AVFoundation, VideoToolbox) | macOS, iOS | `import PlatformCamera` |
| [PlatformScan](docs/PlatformScan.md) | Page text, edges and straightening, PDF pages, redacted copies, document camera (Vision, PDFKit, VisionKit) | iOS; macOS partial (no document camera) | `import PlatformScan` |
| [PlatformNotifications](docs/PlatformNotifications.md) | Local notifications without a push service (UserNotifications) | macOS, iOS | `import PlatformNotifications` |
| [PlatformLanguages](docs/PlatformLanguages.md) | Translations downloaded on request, checked, and used by the app's lookups | macOS, iOS, Linux, Windows | `import PlatformLanguages` |

Where a platform isn't listed, the library has a fallback that says it can't (`isAvailable` or `isSupported` false,
`nil`, or an error); not every fallback has been built on Windows yet, and PlatformMedia has no Windows or Android
engine at all. Android is not built or tested for any library. The
internal targets `CFTS`, `CGStreamer`, `CGio`, `CGdkPixbuf`, `CWebKitGtk` and `CAvahi` are Linux system-library
wrappers the libraries use; apps don't import them.

Run one library's tests with `swift test --filter <Library>Tests`.
