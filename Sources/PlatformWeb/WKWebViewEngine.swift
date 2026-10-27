#if canImport(WebKit)
  import Foundation
  import WebKit

  /// WKWebView behind `PlatformWebPage`: key-value observation of its state, its navigation delegate for decisions
  /// and failures.
  @MainActor
  final class WebEngine: NSObject, WKNavigationDelegate {
    weak var page: PlatformWebPage?
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    override init() {
      webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
      super.init()
      webView.navigationDelegate = self
      let changed: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.update() }
      }
      observations = [
        webView.observe(\.title) { changed($0, $1) }, webView.observe(\.url) { changed($0, $1) },
        webView.observe(\.isLoading) { changed($0, $1) }, webView.observe(\.estimatedProgress) { changed($0, $1) },
        webView.observe(\.canGoBack) { changed($0, $1) }, webView.observe(\.canGoForward) { changed($0, $1) },
      ]
    }

    /// Reads the view's state into the page (only what changed, so observers aren't woken for nothing).
    private func update() {
      guard let page else { return }
      let title = webView.title ?? ""
      if page.title != title { page.title = title }
      if page.url != webView.url { page.url = webView.url }
      if page.isLoading != webView.isLoading { page.isLoading = webView.isLoading }
      if page.estimatedProgress != webView.estimatedProgress { page.estimatedProgress = webView.estimatedProgress }
      if page.canGoBack != webView.canGoBack { page.canGoBack = webView.canGoBack }
      if page.canGoForward != webView.canGoForward { page.canGoForward = webView.canGoForward }
    }

    func load(_ url: URL) {
      if url.isFileURL {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
      } else {
        webView.load(URLRequest(url: url))
      }
    }

    func load(html: String, baseURL: URL?) { webView.loadHTMLString(html, baseURL: baseURL) }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (Result<String?, PlatformWebError>) -> Void) {
      webView.evaluateJavaScript(script) { value, error in
        // WebKit calls back on the main thread.
        let result: Result<String?, PlatformWebError>
        if let error {
          // A script whose value can't cross (a function, a DOM node) or nothing at all is not an error here.
          let code = (error as NSError).code
          result = code == WKError.javaScriptResultTypeIsUnsupported.rawValue ? .success(nil) : .failure(PlatformWebError(error.localizedDescription))
        } else {
          result = .success(Self.text(value))
        }
        MainActor.assumeIsolated { completion(result) }
      }
    }

    nonisolated static func text(_ value: Any?) -> String? {
      switch value {
      case nil, is NSNull: return nil
      case let string as String: return string
      case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
      case let value?:
        guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
      }
    }

    // MARK: WKNavigationDelegate

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      let navigation = PlatformWebNavigation(
        url: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
        isLinkActivated: navigationAction.navigationType == .linkActivated)
      decisionHandler(page?.decide(navigation) == .cancel ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      page?.errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
      failed(error)
    }

    private func failed(_ error: any Error) {
      // A navigation replaced by another one isn't a failure the user needs to see.
      if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
      page?.errorMessage = error.localizedDescription
    }
  }
#endif
