import SwiftUI

#if canImport(WebKit)
  import WebKit
#endif

/// Shows a `PlatformWebPage`, filling the room it's offered. A WKWebView on Apple platforms; a WebKitGTK view placed
/// over the window on Linux (drawn above SwiftUI's own drawing, as native views are elsewhere).
public struct PlatformWebView: View {
  let page: PlatformWebPage

  public init(_ page: PlatformWebPage) { self.page = page }

  public var body: some View {
    NativeWebView(engine: page.engine)
  }
}

#if canImport(AppKit) && canImport(WebKit)
  private struct NativeWebView: NSViewRepresentable {
    let engine: WebEngine
    func makeNSView(context: Context) -> WKWebView { engine.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
  }
#elseif canImport(UIKit) && canImport(WebKit)
  private struct NativeWebView: UIViewRepresentable {
    let engine: WebEngine
    func makeUIView(context: Context) -> WKWebView { engine.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
  }
#elseif os(Linux)
  private struct NativeWebView: GtkWidgetRepresentable {
    let engine: WebEngine
    func makeWidget(context: Context) -> OpaquePointer { OpaquePointer(engine.widget) }
    func updateWidget(_ widget: OpaquePointer, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, widget: OpaquePointer, context: Context) -> CGSize? {
      proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }
  }
#else
  private struct NativeWebView: View {
    let engine: WebEngine
    var body: some View { Color.clear }
  }
#endif
