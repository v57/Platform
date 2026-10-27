import Foundation
import Testing

@testable import PlatformWeb

#if os(Linux)
  import CWebKitGtk
#endif

/// Loads HTML into a page (no window) and reads its state and JavaScript. On Linux it needs a display
/// (`xvfb-run -a swift test`) and is skipped without one.
@MainActor
struct PlatformWebTests {
  nonisolated static var hasEngine: Bool {
    #if os(Linux)
      return ProcessInfo.processInfo.environment["DISPLAY"] != nil
    #else
      return true
    #endif
  }

  /// Spins the main loop (GLib's on Linux) until `condition` holds or `seconds` pass.
  func wait(_ seconds: Double = 20, until condition: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end {
      #if os(Linux)
        while g_main_context_iteration(nil, 0) != 0 {}
      #endif
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test(.enabled(if: hasEngine)) func loadsHTMLAndRunsJavaScript() async throws {
    let page = PlatformWebPage()
    var asked: [PlatformWebNavigation] = []
    page.decidePolicy = { navigation in
      asked.append(navigation)
      return navigation.url?.host == "blocked.invalid" ? .cancel : .allow
    }
    page.load(html: "<html><head><title>Hello Web</title></head><body><a id=l href='https://blocked.invalid/x'>x</a></body></html>", baseURL: URL(string: "https://example.invalid/"))
    await wait { page.title == "Hello Web" && !page.isLoading }
    #expect(page.title == "Hello Web")
    #expect(page.url?.host == "example.invalid")

    var result: Result<String?, PlatformWebError>?
    page.evaluateJavaScript("[1 + 2, document.title, {a: true}]") { result = $0 }
    await wait { result != nil }
    #expect(try result?.get() == #"[3,"Hello Web",{"a":true}]"#)

    result = nil
    page.evaluateJavaScript("document.title.length") { result = $0 }
    await wait { result != nil }
    #expect(try result?.get() == "9")

    // A navigation the page refuses leaves it where it is.
    result = nil
    page.evaluateJavaScript("document.getElementById('l').click(); 'clicked'") { result = $0 }
    await wait { result != nil }
    await wait(3) { asked.contains { $0.url?.host == "blocked.invalid" } }
    #expect(asked.contains { $0.url?.host == "blocked.invalid" && $0.isLinkActivated })
    #expect(page.url?.host == "example.invalid")
  }
}
