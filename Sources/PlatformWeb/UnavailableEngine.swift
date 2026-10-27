#if !canImport(WebKit) && !os(Linux)
  import Foundation

  /// No web engine here (Windows, Android): the page keeps the address it was given and shows nothing.
  @MainActor
  final class WebEngine {
    weak var page: PlatformWebPage?

    func load(_ url: URL) { page?.url = url }
    func load(html: String, baseURL: URL?) { page?.url = baseURL }
    func reload() {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}

    func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (Result<String?, PlatformWebError>) -> Void) {
      completion(.failure(PlatformWebError("No web engine on this platform")))
    }
  }
#endif
