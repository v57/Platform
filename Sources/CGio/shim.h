// GIO's D-Bus for PlatformMedia's Linux backend: an MPRIS server (org.mpris.MediaPlayer2), the freedesktop
// interface desktops use for media keys and their now-playing widgets. Install: apt install libglib2.0-dev.
#ifndef PLATFORM_MEDIA_CGIO_SHIM_H
#define PLATFORM_MEDIA_CGIO_SHIM_H

#include <gio/gio.h>
#include <string.h>

/// Called on the thread whose main context registered the server (the main thread under GTK) with an MPRIS method
/// name: "Play", "Pause", "PlayPause", "Stop", "Next" or "Previous".
typedef void (*pm_mpris_command)(void *context, const char *method);

typedef struct {
  GDBusConnection *connection;
  GDBusNodeInfo *node;
  guint owner, root, player;
  pm_mpris_command command;
  void *context;
  gchar *identity, *status, *title;
  gint64 length, position;
  gboolean has_item;
} pm_mpris;

static const char pm_mpris_xml[] =
    "<node>"
    "<interface name='org.mpris.MediaPlayer2'>"
    "<method name='Raise'/><method name='Quit'/>"
    "<property name='CanQuit' type='b' access='read'/><property name='CanRaise' type='b' access='read'/>"
    "<property name='HasTrackList' type='b' access='read'/><property name='Identity' type='s' access='read'/>"
    "<property name='SupportedUriSchemes' type='as' access='read'/>"
    "<property name='SupportedMimeTypes' type='as' access='read'/>"
    "</interface>"
    "<interface name='org.mpris.MediaPlayer2.Player'>"
    "<method name='Next'/><method name='Previous'/><method name='Pause'/><method name='PlayPause'/>"
    "<method name='Stop'/><method name='Play'/>"
    "<method name='Seek'><arg direction='in' name='Offset' type='x'/></method>"
    "<method name='SetPosition'><arg direction='in' name='TrackId' type='o'/>"
    "<arg direction='in' name='Position' type='x'/></method>"
    "<method name='OpenUri'><arg direction='in' name='Uri' type='s'/></method>"
    "<signal name='Seeked'><arg name='Position' type='x'/></signal>"
    "<property name='PlaybackStatus' type='s' access='read'/><property name='Rate' type='d' access='read'/>"
    "<property name='Metadata' type='a{sv}' access='read'/><property name='Volume' type='d' access='read'/>"
    "<property name='Position' type='x' access='read'/><property name='MinimumRate' type='d' access='read'/>"
    "<property name='MaximumRate' type='d' access='read'/><property name='CanGoNext' type='b' access='read'/>"
    "<property name='CanGoPrevious' type='b' access='read'/><property name='CanPlay' type='b' access='read'/>"
    "<property name='CanPause' type='b' access='read'/><property name='CanSeek' type='b' access='read'/>"
    "<property name='CanControl' type='b' access='read'/>"
    "</interface>"
    "</node>";

static inline void pm_mpris_method_call(GDBusConnection *connection, const gchar *sender, const gchar *path,
                                        const gchar *interface, const gchar *method, GVariant *parameters,
                                        GDBusMethodInvocation *invocation, gpointer user) {
  pm_mpris *server = (pm_mpris *)user;
  if (strcmp(interface, "org.mpris.MediaPlayer2.Player") == 0) server->command(server->context, method);
  g_dbus_method_invocation_return_value(invocation, NULL);
}

static inline GVariant *pm_mpris_metadata(pm_mpris *server) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
  if (server->has_item) {
    g_variant_builder_add(&builder, "{sv}", "mpris:trackid",
                          g_variant_new_object_path("/org/mpris/MediaPlayer2/Track/1"));
    if (server->length > 0) g_variant_builder_add(&builder, "{sv}", "mpris:length", g_variant_new_int64(server->length));
    g_variant_builder_add(&builder, "{sv}", "xesam:title", g_variant_new_string(server->title ? server->title : ""));
  }
  return g_variant_builder_end(&builder);
}

static inline GVariant *pm_mpris_get_property(GDBusConnection *connection, const gchar *sender, const gchar *path,
                                              const gchar *interface, const gchar *name, GError **error,
                                              gpointer user) {
  pm_mpris *server = (pm_mpris *)user;
  if (!strcmp(name, "CanQuit") || !strcmp(name, "CanRaise") || !strcmp(name, "HasTrackList") ||
      !strcmp(name, "CanSeek"))
    return g_variant_new_boolean(FALSE);
  if (!strcmp(name, "Identity")) return g_variant_new_string(server->identity);
  if (!strcmp(name, "SupportedUriSchemes") || !strcmp(name, "SupportedMimeTypes")) return g_variant_new_strv(NULL, 0);
  if (!strcmp(name, "PlaybackStatus")) return g_variant_new_string(server->status);
  if (!strcmp(name, "Rate") || !strcmp(name, "MinimumRate") || !strcmp(name, "MaximumRate") ||
      !strcmp(name, "Volume"))
    return g_variant_new_double(1.0);
  if (!strcmp(name, "Metadata")) return pm_mpris_metadata(server);
  if (!strcmp(name, "Position")) return g_variant_new_int64(server->position);
  if (!strcmp(name, "CanGoNext") || !strcmp(name, "CanGoPrevious") || !strcmp(name, "CanPlay") ||
      !strcmp(name, "CanPause"))
    return g_variant_new_boolean(server->has_item);
  if (!strcmp(name, "CanControl")) return g_variant_new_boolean(TRUE);
  return NULL;
}

static const GDBusInterfaceVTable pm_mpris_vtable = {pm_mpris_method_call, pm_mpris_get_property, NULL, {0}};

/// Registers the MPRIS object on the session bus and owns `org.mpris.MediaPlayer2.<bus_suffix>`; NULL without a
/// session bus.
static inline pm_mpris *pm_mpris_new(const char *bus_suffix, const char *identity, pm_mpris_command command,
                                     void *context) {
  GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  if (!connection) return NULL;
  pm_mpris *server = g_new0(pm_mpris, 1);
  server->connection = connection;
  server->command = command;
  server->context = context;
  server->identity = g_strdup(identity);
  server->status = g_strdup("Stopped");
  server->node = g_dbus_node_info_new_for_xml(pm_mpris_xml, NULL);
  server->root = g_dbus_connection_register_object(connection, "/org/mpris/MediaPlayer2", server->node->interfaces[0],
                                                   &pm_mpris_vtable, server, NULL, NULL);
  server->player = g_dbus_connection_register_object(connection, "/org/mpris/MediaPlayer2",
                                                     server->node->interfaces[1], &pm_mpris_vtable, server, NULL, NULL);
  gchar *name = g_strdup_printf("org.mpris.MediaPlayer2.%s", bus_suffix);
  server->owner = g_bus_own_name_on_connection(connection, name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
  g_free(name);
  return server;
}

/// The item and status ("Playing", "Paused", "Stopped"); announces the properties that changed (the position is
/// read when asked, as MPRIS wants).
static inline void pm_mpris_update(pm_mpris *server, gboolean has_item, const char *title, gint64 length,
                                   gint64 position, const char *status) {
  gboolean changed = has_item != server->has_item || length != server->length ||
                     g_strcmp0(title, server->title) != 0 || g_strcmp0(status, server->status) != 0;
  server->has_item = has_item;
  server->length = length;
  server->position = position;
  g_free(server->title);
  server->title = g_strdup(title);
  g_free(server->status);
  server->status = g_strdup(status);
  if (!changed) return;
  GVariantBuilder properties;
  g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&properties, "{sv}", "PlaybackStatus", g_variant_new_string(status));
  g_variant_builder_add(&properties, "{sv}", "Metadata", pm_mpris_metadata(server));
  const char *flags[] = {"CanPlay", "CanPause", "CanGoNext", "CanGoPrevious"};
  for (int index = 0; index < 4; index++)
    g_variant_builder_add(&properties, "{sv}", flags[index], g_variant_new_boolean(has_item));
  g_dbus_connection_emit_signal(server->connection, NULL, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
                                "PropertiesChanged",
                                g_variant_new("(sa{sv}as)", "org.mpris.MediaPlayer2.Player", &properties, NULL), NULL);
}

static inline void pm_mpris_free(pm_mpris *server) {
  if (!server) return;
  g_bus_unown_name(server->owner);
  g_dbus_connection_unregister_object(server->connection, server->root);
  g_dbus_connection_unregister_object(server->connection, server->player);
  g_dbus_node_info_unref(server->node);
  g_object_unref(server->connection);
  g_free(server->identity);
  g_free(server->status);
  g_free(server->title);
  g_free(server);
}

#endif
