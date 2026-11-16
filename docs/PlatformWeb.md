# PlatformWeb

A web page and its SwiftUI view. Part of [Platform](../README.md).

<!-- platforms: macos ios linux windows=planned android=planned -->

## Purpose

`PlatformWeb` replaces WebKit's `WKWebView` and its navigation delegate with an observable page model and a view:
load a URL or HTML, go back and forward, read the title and loading state, run JavaScript, and decide about
navigations. The same code shows WebKitGTK on Linux.

It is not a browser: there are no tabs, downloads, cookies or content-blocker APIs, and no access to the engine's
own objects.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformWeb", package: "Platform"),
```

```swift
import PlatformWeb
import SwiftUI

struct HelpView: View {
  @State private var page = PlatformWebPage()

  var body: some View {
    PlatformWebView(page)
      .onAppear {
        page.decidePolicy = { navigation in
          navigation.url?.host == "example.com" ? .allow : .cancel
        }
        page.load(URL(string: "https://example.com/help")!)
      }
      .navigationTitle(page.title)
  }
}
```

## Main API

- `PlatformWebPage()`: a main-actor, `@Observable` page.
  - Observable state: `url` (the committed navigation's), `title`, `isLoading`, `estimatedProgress`, `canGoBack`,
    `canGoForward`, `errorMessage`.
  - `load(_:)`, `load(html:baseURL:)`, `reload()`, `stopLoading()`, `goBack()`, `goForward()`.
  - `evaluateJavaScript(_:) async throws -> String?`: runs a script in the main frame and returns its value as text:
    a string as it is, a number or boolean as written, an object or array as JSON, nil for `undefined` and `null`.
    A completion-handler form `evaluateJavaScript(_:completion:)` takes a `Result<String?, PlatformWebError>`.
  - `decidePolicy`: called for navigations, link clicks and new windows with a `PlatformWebNavigation` (`url`,
    `isMainFrame`, `isLinkActivated`); return `.allow` or `.cancel` (`PlatformWebPolicy`). Without it everything is
    allowed.
- `PlatformWebView(_:)`: the SwiftUI view showing a page.

## Backends

- **macOS, iOS**: `WKWebView`, observed with key-value observation, and its navigation delegate.
- **Linux**: WebKitGTK 4.1, shown through v57/SwiftUI's GTK backend as a native view placed over the window (drawn
  above SwiftUI's own drawing). Build with `apt install libwebkit2gtk-4.1-dev`;
  run with `libwebkit2gtk-4.1-0`. It draws without the GPU (WebKit's GPU path fails in VMs and over remote X) unless
  `PLATFORM_WEB_GPU=1` is set.
- **Windows, Android**: no engine. The page keeps the address it was given and the view shows nothing.

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: builds on the Ubuntu VM. The view comes from v57/SwiftUI (GitHub's `main`, or `../SwiftUI` with
  `V57_LOCAL=1`).
- **Windows, Android**: placeholder only, as above.

## Testing

```bash
swift test --filter PlatformWebTests
xvfb-run -a swift test --filter PlatformWebTests     # Linux: the engine needs a display
```

The test loads HTML into a page with no window and reads its state and JavaScript. On Linux it is skipped when
`DISPLAY` isn't set.

## Related

- [SwiftUI](../../SwiftUI/docs/SwiftUI.md): `PlatformWebView` on Linux, through its GTK backend's `GtkWidgetRepresentable`.
- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
