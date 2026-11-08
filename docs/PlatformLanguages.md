# PlatformLanguages

Translations downloaded on request and answered in front of the app's own strings. Part of [Platform](../README.md).

## Purpose

An app ships with a few languages and can offer more without growing: `PlatformLanguages` downloads a language's
`.strings` and `.stringsdict` files from [v57/Localizations](https://github.com/v57/Localizations) when the user asks,
checks every line, and makes the app's normal lookups find them. `Text("Open")`, `String(localized:)`,
`LocalizedStringResource`, `AttributedString(localized:)`, menus and `NSLocalizedString` all show the downloaded
translation like a bundled one. It stands in for the per-app language support of Apple's bundles, which only knows
the languages inside the app.

It is not a translation tool or a string-catalog compiler, and it never downloads or checks anything unless the app
asks (on the user's word).

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformLanguages", package: "Platform"),
```

Start the packs first thing, before any text resolves, naming the app's string sources (its own bundle's name, then
the kits' it shows strings from):

```swift
import PlatformLanguages
import SwiftUI

@main struct MyApp: App {
  init() { LanguagePacks.start(sources: ["MyApp", "ComponentKit"]) }

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}
```

v57 apps then use ComponentKit's Settings ▸ Languages pane and its `kitLanguages()` modifier, which offer the app's
language once and list, download, update and remove languages. An app with its own UI drives `LanguagePacks.shared`:

```swift
@MainActor func downloadOfferedLanguage() async throws {
  let packs = LanguagePacks.shared
  guard let offer = packs.offer else { return }   // the app's language, downloadable, not offered before
  packs.dismissOffer()
  try await packs.download(offer.code)
}
```

## What a release must contain

The packs read the app's `Info.plist`:

| Key | Type | What it does |
|---|---|---|
| `CFBundleLocalizations` | array | Every language the app runs in, the downloadable ones included (with a stub `.lproj`), so the system can pick one per app. |
| `V57Languages` | dictionary, code → bytes | The languages this release can download and their sizes, so the list needs no request. |
| `V57LocalizationsCommit` | string | The v57/Localizations commit (40 lowercase hex digits) the release was built with. Downloads come from that commit only. |
| `V57LocalizationsManifest` | string | The SHA-256 (hex) of that commit's `manifest.json`. The manifest read must match it. |

Security behaviour:

- A Release build without `V57LocalizationsCommit` downloads and offers nothing (`LanguagePackError.unavailable`).
- Files come from `https://raw.githubusercontent.com/v57/Localizations/<commit>/`. Every file must match the SHA-256
  the manifest lists for it, or the download fails with `badFile`.
- Language codes, file names and sources in the manifest that aren't plain names (`../x.strings`) are dropped when it
  is read and checked again before a path is made.
- Every downloaded line is checked against its key's format specifiers (`FormatCheck`). A line whose `%@`, `%d`,
  `%s` or `%n` doesn't fit the arguments the app passes would crash `String(format:)` or read the wrong memory, so it
  is dropped and the key shows in English.

In a Debug build: without a commit the packs read `main`; `V57_LOCALIZATIONS_URL` (a folder path or a server URL)
replaces the source for testing, and a Release build ignores it; `-V57Languages '{de = 1200;}'` in the launch
arguments stands in for a release's list.

## Main API

- `LanguagePacks.start(sources:)`: names the sources and uses the downloaded pack of the app's language. Call in the
  App's `init`.
- `LanguagePacks.shared` (main actor, `@Observable`):
  - `language`: the language the app runs in ("de"). Only that language's pack is used.
  - `languages`: every language the app has, can download or has downloaded (`LanguagePacks.Language`: `code`,
    `name`, `ownName`, `state`, `isActive`), the app's language first. `State`: `.included`,
    `.available(bytes:)`, `.downloading`, `.downloaded(bytes:updateAvailable:)`.
  - `offer`, `dismissOffer()`: the app's language when it can be downloaded and hasn't been offered; ask once.
  - `checkForUpdates() async throws -> Bool`: reads the manifest; true when a downloaded language has newer files.
  - `download(_:) async throws`: downloads (or updates) a language for the app's sources and uses it at once when the
    app runs in it.
  - `remove(_:)`: deletes a downloaded language; the app goes back to its development language.
  - `revision`: changes whenever the app's strings change; views rebuilt on it show the new strings.
  - `sources`, `checked` (when the manifest was last read in this launch).
- `LanguagePackError`: `.noTranslations(String)`, `.server(Int)`, `.badManifest`, `.badFile(String)`,
  `.unavailable`.
- `FormatCheck`: `fits(_:key:)`, `fits(pluralEntry:key:)`, `checkedStrings(_:)` and `checkedStringsdict(_:)` (a
  table with the misfits dropped, and the dropped keys), for checking translations elsewhere.

Downloaded files live in Application Support (`~/.local/share` on Linux, `%APPDATA%` on Windows) under the app's
bundle identifier, in `Languages/<code>/`.

## Backends

- **macOS, iOS**: the main bundle becomes a subclass whose string lookups ask the pack's bundles first, then the
  bundle itself. The lookups SwiftUI, AppKit, UIKit and Foundation use are added only when `NSBundle` has them, so an
  OS that renames a private one shows English there and never crashes. The app's language is the system's pick from
  `CFBundleLocalizations`.
- **Linux, Windows**: v57/SwiftUI asks the pack's bundles itself, and the app's language is SwiftUI's `AppLanguage`.
  When the app's build lacks the language's ICU formats, they are downloaded with it. CryptoKit is v57/SwiftUI's
  stand-in (swift-crypto).
- **Android**: not built or tested.

## Platform notes

- **macOS, iOS**: supported. The lookup hook was checked on macOS 27 and iOS 27.2.
- **Linux**: depends on v57/SwiftUI (GitHub's `main`, or `../SwiftUI` with `V57_LOCAL=1`).
- **Windows**: the same code as Linux; not verified on Windows yet.

## Testing

```bash
swift test --filter PlatformLanguagesTests
```

The tests cover the format checks, download, update and removal from a local folder, manifests that name paths, files
and manifests that don't match their hashes, where downloads come from per build, and, on Apple platforms, the main
bundle answering from a pack. No network is needed.
