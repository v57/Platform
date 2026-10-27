import Foundation
import Observation

/// A navigation a `PlatformWebPage` is about to make, for its `decidePolicy`.
public struct PlatformWebNavigation: Sendable {
  /// Where it goes.
  public var url: URL?
  /// False for a page that asked for a new window (a link with `target="_blank"`, `window.open`).
  public var isMainFrame: Bool
  /// A click on a link (rather than a script, a form, a reload or the history).
  public var isLinkActivated: Bool

  public init(url: URL?, isMainFrame: Bool, isLinkActivated: Bool) {
    self.url = url
    self.isMainFrame = isMainFrame
    self.isLinkActivated = isLinkActivated
  }
}

/// What a page does with a navigation.
public enum PlatformWebPolicy: Sendable {
  case allow
  case cancel
}

public struct PlatformWebError: Error, CustomStringConvertible, Sendable {
  public var description: String
  public init(_ description: String) { self.description = description }
}

/// A web page: its address, title and loading state (observable), navigation and JavaScript. Show it with
/// `PlatformWebView`. WKWebView on Apple platforms, WebKitGTK on Linux (`apt install libwebkit2gtk-4.1-0`).
///
/// ```swift
/// @State private var page = PlatformWebPage()
/// var body: some View {
///   PlatformWebView(page)
///     .onAppear { page.load(URL(string: "https://example.com")!) }
///     .navigationTitle(page.title)
/// }
/// ```
@MainActor @Observable
public final class PlatformWebPage {
  /// The page's address (the committed navigation's).
  public internal(set) var url: URL?
  /// The document's `<title>` (empty until it has one).
  public internal(set) var title = ""
  public internal(set) var isLoading = false
  /// 0...1 while loading.
  public internal(set) var estimatedProgress = 0.0
  public internal(set) var canGoBack = false
  public internal(set) var canGoForward = false
  /// Why the last navigation failed (nil after a load that worked).
  public internal(set) var errorMessage: String?

  /// Asked before every navigation (links, scripts, redirects; not `load` calls). Nil allows everything.
  @ObservationIgnored public var decidePolicy: (@MainActor (PlatformWebNavigation) -> PlatformWebPolicy)?

  @ObservationIgnored let engine = WebEngine()

  public init() {
    engine.page = self
  }

  public func load(_ url: URL) {
    errorMessage = nil
    engine.load(url)
  }

  /// Shows `html`, resolving relative addresses against `baseURL`.
  public func load(html: String, baseURL: URL? = nil) {
    errorMessage = nil
    engine.load(html: html, baseURL: baseURL)
  }

  public func reload() { engine.reload() }
  public func stopLoading() { engine.stopLoading() }
  public func goBack() { engine.goBack() }
  public func goForward() { engine.goForward() }

  /// Runs `script` in the page's main frame and gives back its value as text: a string as it is, a number or a
  /// boolean as written, an object or an array as JSON, nil for `undefined` and `null`.
  public func evaluateJavaScript(_ script: String) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      engine.evaluateJavaScript(script) { continuation.resume(with: $0) }
    }
  }

  /// `evaluateJavaScript` with a completion handler (on the main actor).
  public func evaluateJavaScript(
    _ script: String, completion: @escaping @MainActor (Result<String?, PlatformWebError>) -> Void
  ) {
    engine.evaluateJavaScript(script, completion: completion)
  }

  // The engines report here.

  func decide(_ navigation: PlatformWebNavigation) -> PlatformWebPolicy {
    decidePolicy?(navigation) ?? .allow
  }
}
