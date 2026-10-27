// WebKitGTK (the GTK 3 API, webkit2gtk-4.1) for PlatformWeb's Linux backend: the headers, plus the casts and signal
// connection Swift can't call (GObject macros). Install: apt install libwebkit2gtk-4.1-dev.
#ifndef PLATFORM_WEB_CWEBKITGTK_SHIM_H
#define PLATFORM_WEB_CWEBKITGTK_SHIM_H

#include <webkit2/webkit2.h>
#include <string.h>

static inline WebKitWebView *pw_web_view(gpointer object) { return WEBKIT_WEB_VIEW(object); }
static inline WebKitNavigationPolicyDecision *pw_navigation_decision(gpointer object) {
  return WEBKIT_NAVIGATION_POLICY_DECISION(object);
}

static inline gulong pw_signal_connect(gpointer instance, const char *signal, GCallback callback, gpointer data) {
  return g_signal_connect_data(instance, signal, callback, data, NULL, (GConnectFlags)0);
}

/// Disconnects every handler that gets `data` (G_SIGNAL_MATCH_DATA).
static inline void pw_signal_disconnect_data(gpointer instance, gpointer data) {
  g_signal_handlers_disconnect_matched(instance, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, data);
}

/// A web view whose content is drawn without the GPU when `software` (VMs, remote X sessions).
static inline GtkWidget *pw_web_view_new(gboolean software) {
  GtkWidget *view = webkit_web_view_new();
  if (software) {
    WebKitSettings *settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(view));
    webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
  }
  return view;
}

#endif
