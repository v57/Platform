#if os(Linux)
  import Foundation
  import CWebKitGtk

  /// WebKitGTK behind `PlatformWebPage`: a `WebKitWebView` (a GTK 3 widget, shown by `PlatformWebView` through
  /// SwiftUIGtk's `GtkWidgetRepresentable`) whose property notifications update the page. Drawn without the GPU
  /// unless `PLATFORM_WEB_GPU=1` (WebKit's GPU path fails in VMs and over remote X).
  @MainActor
  final class WebEngine {
    weak var page: PlatformWebPage?
    /// The `GtkWidget *` (a reference the engine keeps for its life).
    let widget: UnsafeMutablePointer<GtkWidget>
    private var view: UnsafeMutablePointer<WebKitWebView> { pw_web_view(UnsafeMutableRawPointer(widget)) }

    init() {
      if gtk_init_check(nil, nil) == 0 { FileHandle.standardError.write(Data("PlatformWeb: no display for GTK\n".utf8)) }
      let gpu = ProcessInfo.processInfo.environment["PLATFORM_WEB_GPU"] == "1"
      widget = pw_web_view_new(gpu ? 0 : 1)
      g_object_ref_sink(UnsafeMutableRawPointer(widget))
      connectSignals()
    }

    isolated deinit {
      pw_signal_disconnect_data(UnsafeMutableRawPointer(widget), Unmanaged.passUnretained(self).toOpaque())
      gtk_widget_destroy(widget)
      g_object_unref(UnsafeMutableRawPointer(widget))
    }

    private func connectSignals() {
      let data = Unmanaged.passUnretained(self).toOpaque()
      let notify: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, _, data in
        MainActor.assumeIsolated { WebEngine.from(data).update() }
      }
      for property in ["title", "uri", "is-loading", "estimated-load-progress"] {
        connect("notify::\(property)", data, notify)
      }
      let changed: @convention(c) (gpointer?, WebKitLoadEvent, gpointer?) -> Void = { _, event, data in
        MainActor.assumeIsolated {
          let engine = WebEngine.from(data)
          if event == WEBKIT_LOAD_FINISHED, engine.failed == false { engine.page?.errorMessage = nil }
          if event == WEBKIT_LOAD_STARTED { engine.failed = false }
          engine.update()
        }
      }
      connect("load-changed", data, changed)
      let failed: @convention(c) (gpointer?, WebKitLoadEvent, UnsafePointer<CChar>?, UnsafeMutablePointer<GError>?, gpointer?) -> gboolean = {
        _, _, _, error, data in
        MainActor.assumeIsolated {
          let engine = WebEngine.from(data)
          guard let error else { return }
          // A load another navigation replaced (WEBKIT_NETWORK_ERROR_CANCELLED) isn't a failure the user sees.
          if error.pointee.domain == webkit_network_error_quark(), error.pointee.code == WEBKIT_NETWORK_ERROR_CANCELLED.rawValue { return }
          // A policy decision that stopped a navigation ("Frame load interrupted") isn't one either.
          if error.pointee.domain == webkit_policy_error_quark() { return }
          engine.failed = true
          engine.page?.errorMessage = String(cString: error.pointee.message)
        }
        return 0  // WebKit shows its error page
      }
      connect("load-failed", data, failed)
      let decide: @convention(c) (gpointer?, gpointer?, WebKitPolicyDecisionType, gpointer?) -> gboolean = { _, decision, type, data in
        MainActor.assumeIsolated { WebEngine.from(data).decide(decision, type: type) }
      }
      connect("decide-policy", data, decide)
    }

    private var failed = false

    private func connect<F>(_ signal: String, _ data: UnsafeMutableRawPointer, _ callback: F) {
      _ = pw_signal_connect(UnsafeMutableRawPointer(widget), signal, unsafeBitCast(callback, to: GCallback.self), data)
    }

    private static func from(_ data: gpointer?) -> WebEngine {
      Unmanaged<WebEngine>.fromOpaque(data!).takeUnretainedValue()
    }

    /// Reads the view's state into the page (only what changed, so observers aren't woken for nothing).
    private func update() {
      guard let page else { return }
      let title = webkit_web_view_get_title(view).map { String(cString: $0) } ?? ""
      if page.title != title { page.title = title }
      let url = webkit_web_view_get_uri(view).flatMap { URL(string: String(cString: $0)) }
      if page.url != url { page.url = url }
      let loading = webkit_web_view_is_loading(view) != 0
      if page.isLoading != loading { page.isLoading = loading }
      let progress = webkit_web_view_get_estimated_load_progress(view)
      if page.estimatedProgress != progress { page.estimatedProgress = progress }
      let back = webkit_web_view_can_go_back(view) != 0
      if page.canGoBack != back { page.canGoBack = back }
      let forward = webkit_web_view_can_go_forward(view) != 0
      if page.canGoForward != forward { page.canGoForward = forward }
    }

    private func decide(_ decision: gpointer?, type: WebKitPolicyDecisionType) -> gboolean {
      guard let page, let decision,
        type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION
      else { return 0 }
      let navigationDecision = pw_navigation_decision(decision)
      guard let action = webkit_navigation_policy_decision_get_navigation_action(navigationDecision) else { return 0 }
      let request = webkit_navigation_action_get_request(action)
      let url = webkit_uri_request_get_uri(request).flatMap { URL(string: String(cString: $0)) }
      let navigation = PlatformWebNavigation(
        url: url, isMainFrame: type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION,
        isLinkActivated: webkit_navigation_action_get_navigation_type(action) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED)
      let raw = UnsafeMutablePointer<WebKitPolicyDecision>(OpaquePointer(decision))
      switch page.decide(navigation) {
      case .allow: webkit_policy_decision_use(raw)
      case .cancel: webkit_policy_decision_ignore(raw)
      }
      return 1
    }

    func load(_ url: URL) { webkit_web_view_load_uri(view, url.absoluteString) }
    func load(html: String, baseURL: URL?) { webkit_web_view_load_html(view, html, baseURL?.absoluteString) }
    func reload() { webkit_web_view_reload(view) }
    func stopLoading() { webkit_web_view_stop_loading(view) }
    func goBack() { webkit_web_view_go_back(view) }
    func goForward() { webkit_web_view_go_forward(view) }

    private final class Evaluation {
      let completion: @MainActor (Result<String?, PlatformWebError>) -> Void
      init(_ completion: @escaping @MainActor (Result<String?, PlatformWebError>) -> Void) { self.completion = completion }
    }

    func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (Result<String?, PlatformWebError>) -> Void) {
      let box = Unmanaged.passRetained(Evaluation(completion)).toOpaque()
      let done: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { source, result, data in
        let evaluation = Unmanaged<Evaluation>.fromOpaque(data!).takeRetainedValue()
        var error: UnsafeMutablePointer<GError>?
        let value = webkit_web_view_evaluate_javascript_finish(
          pw_web_view(UnsafeMutableRawPointer(source)), result, &error)
        let outcome: Result<String?, PlatformWebError>
        if let error {
          outcome = .failure(PlatformWebError(String(cString: error.pointee.message)))
          g_error_free(error)
        } else {
          outcome = .success(WebEngine.text(value))
        }
        if let value { g_object_unref(UnsafeMutableRawPointer(value)) }
        MainActor.assumeIsolated { evaluation.completion(outcome) }
      }
      webkit_web_view_evaluate_javascript(view, script, -1, nil, nil, nil, done, box)
    }

    /// A JavaScript value as `PlatformWebPage.evaluateJavaScript` gives it back.
    private nonisolated static func text(_ value: UnsafeMutablePointer<JSCValue>?) -> String? {
      guard let value, jsc_value_is_undefined(value) == 0, jsc_value_is_null(value) == 0 else { return nil }
      let string: UnsafeMutablePointer<CChar>?
      if jsc_value_is_string(value) != 0 || jsc_value_is_number(value) != 0 || jsc_value_is_boolean(value) != 0 {
        string = jsc_value_to_string(value)
      } else {
        string = jsc_value_to_json(value, 0) ?? jsc_value_to_string(value)
      }
      guard let string else { return nil }
      defer { g_free(string) }
      return String(cString: string)
    }
  }
#endif
