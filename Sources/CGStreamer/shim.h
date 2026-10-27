// GStreamer for PlatformMedia's Linux backend: the headers, plus small helpers for what Swift can't call directly
// (variadic g_object_set/get and signal emission, header-only macros and inline functions, appsink callbacks).
// Install: apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev (and the plugin packages for codecs).
#ifndef PLATFORM_MEDIA_CGSTREAMER_SHIM_H
#define PLATFORM_MEDIA_CGSTREAMER_SHIM_H

#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <string.h>

/// playbin's GstPlayFlags (the enum lives in the plugin, not in a public header).
enum {
  PM_PLAY_FLAG_VIDEO = 1 << 0,
  PM_PLAY_FLAG_AUDIO = 1 << 1,
  PM_PLAY_FLAG_TEXT = 1 << 2,
};

// MARK: Properties

static inline void pm_set_bool(gpointer object, const char *name, gboolean value) { g_object_set(object, name, value, NULL); }
static inline void pm_set_int(gpointer object, const char *name, gint value) { g_object_set(object, name, value, NULL); }
static inline void pm_set_uint(gpointer object, const char *name, guint value) { g_object_set(object, name, value, NULL); }
static inline void pm_set_double(gpointer object, const char *name, gdouble value) { g_object_set(object, name, value, NULL); }
static inline void pm_set_string(gpointer object, const char *name, const char *value) { g_object_set(object, name, value, NULL); }
static inline void pm_set_object(gpointer object, const char *name, gpointer value) { g_object_set(object, name, value, NULL); }

static inline gint pm_get_int(gpointer object, const char *name) {
  gint value = 0;
  g_object_get(object, name, &value, NULL);
  return value;
}
static inline guint pm_get_uint(gpointer object, const char *name) {
  guint value = 0;
  g_object_get(object, name, &value, NULL);
  return value;
}

// MARK: Pipeline

static inline gboolean pm_query_position(GstElement *element, gint64 *nanoseconds) {
  return gst_element_query_position(element, GST_FORMAT_TIME, nanoseconds);
}
static inline gboolean pm_query_duration(GstElement *element, gint64 *nanoseconds) {
  return gst_element_query_duration(element, GST_FORMAT_TIME, nanoseconds);
}

/// A flushing seek to `position` (ns) playing on at `rate`: to the nearest keyframe unless `accurate`.
static inline gboolean pm_seek(GstElement *element, gdouble rate, gint64 position, gboolean accurate) {
  GstSeekFlags flags = (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | (accurate ? GST_SEEK_FLAG_ACCURATE : GST_SEEK_FLAG_KEY_UNIT));
  return gst_element_seek(element, rate, GST_FORMAT_TIME, flags, GST_SEEK_TYPE_SET, position, GST_SEEK_TYPE_NONE,
                          GST_CLOCK_TIME_NONE);
}

static inline void pm_object_unref(gpointer object) { if (object) gst_object_unref(object); }

// MARK: Messages

static inline GstMessageType pm_message_type(GstMessage *message) { return GST_MESSAGE_TYPE(message); }
static inline GstObject *pm_message_source(GstMessage *message) { return GST_MESSAGE_SRC(message); }
static inline void pm_message_unref(GstMessage *message) { gst_message_unref(message); }

/// The error's text (free with g_free).
static inline gchar *pm_message_error(GstMessage *message) {
  GError *error = NULL;
  gchar *debug = NULL;
  gst_message_parse_error(message, &error, &debug);
  gchar *text = g_strdup(error && error->message ? error->message : "Playback failed");
  if (error) g_error_free(error);
  g_free(debug);
  return text;
}

static inline GstState pm_message_new_state(GstMessage *message) {
  GstState old = GST_STATE_NULL, current = GST_STATE_NULL, pending = GST_STATE_NULL;
  gst_message_parse_state_changed(message, &old, &current, &pending);
  return current;
}

// MARK: Streams (playbin's get-*-tags / get-*-pad signals)

/// `signal` is "get-video-tags", "get-audio-tags" or "get-text-tags"; free with pm_tags_unref.
static inline GstTagList *pm_stream_tags(GstElement *playbin, const char *signal, gint index) {
  GstTagList *tags = NULL;
  g_signal_emit_by_name(playbin, signal, index, &tags);
  return tags;
}
static inline void pm_tags_unref(GstTagList *tags) { if (tags) gst_tag_list_unref(tags); }

/// A string tag (free with g_free), NULL when missing.
static inline gchar *pm_tag_string(const GstTagList *tags, const char *tag) {
  gchar *value = NULL;
  if (tags && gst_tag_list_get_string(tags, tag, &value)) return value;
  return NULL;
}

/// An integer field of a stream's negotiated caps ("channels", "rate", "width", ...): `signal` is "get-video-pad",
/// "get-audio-pad" or "get-text-pad".
static inline gboolean pm_stream_caps_int(GstElement *playbin, const char *signal, gint index, const char *field,
                                          gint *value) {
  GstPad *pad = NULL;
  g_signal_emit_by_name(playbin, signal, index, &pad);
  if (!pad) return FALSE;
  gboolean found = FALSE;
  GstCaps *caps = gst_pad_get_current_caps(pad);
  if (caps) {
    if (gst_caps_get_size(caps) > 0) found = gst_structure_get_int(gst_caps_get_structure(caps, 0), field, value);
    gst_caps_unref(caps);
  }
  gst_object_unref(pad);
  return found;
}

// MARK: Video frames (appsink)

/// Called on a streaming thread with a mapped frame: packed pixels in the sink's caps format, rows `stride` bytes
/// apart, and the pixel aspect ratio.
typedef void (*pm_frame_callback)(void *context, const guint8 *data, gint width, gint height, gint stride,
                                  gint par_n, gint par_d);

typedef struct {
  pm_frame_callback callback;
  void *context;
} pm_frame_target;

static inline void pm_frame_deliver(pm_frame_target *target, GstSample *sample) {
  if (!sample) return;
  GstCaps *caps = gst_sample_get_caps(sample);
  GstBuffer *buffer = gst_sample_get_buffer(sample);
  GstVideoInfo info;
  GstMapInfo map;
  if (caps && buffer && gst_video_info_from_caps(&info, caps)) {
    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
      target->callback(target->context, map.data, GST_VIDEO_INFO_WIDTH(&info), GST_VIDEO_INFO_HEIGHT(&info),
                       GST_VIDEO_INFO_PLANE_STRIDE(&info, 0), GST_VIDEO_INFO_PAR_N(&info),
                       GST_VIDEO_INFO_PAR_D(&info));
      gst_buffer_unmap(buffer, &map);
    }
  }
  gst_sample_unref(sample);
}

static inline GstFlowReturn pm_frame_new_sample(GstAppSink *sink, gpointer user) {
  pm_frame_deliver((pm_frame_target *)user, gst_app_sink_pull_sample(sink));
  return GST_FLOW_OK;
}

static inline GstFlowReturn pm_frame_new_preroll(GstAppSink *sink, gpointer user) {
  pm_frame_deliver((pm_frame_target *)user, gst_app_sink_pull_preroll(sink));
  return GST_FLOW_OK;
}

/// An appsink that takes `caps` (e.g. "video/x-raw,format=BGRx"), keeps at most two frames (dropping late ones)
/// and hands each frame, the preroll one included, to `callback`.
static inline GstElement *pm_frame_sink_new(const char *caps_string, pm_frame_callback callback, void *context) {
  GstElement *sink = gst_element_factory_make("appsink", "platform-media-video");
  if (!sink) return NULL;
  GstCaps *caps = gst_caps_from_string(caps_string);
  g_object_set(sink, "caps", caps, "max-buffers", (guint)2, "drop", TRUE, "sync", TRUE, NULL);
  gst_caps_unref(caps);
  pm_frame_target *target = g_new0(pm_frame_target, 1);
  target->callback = callback;
  target->context = context;
  GstAppSinkCallbacks callbacks;
  memset(&callbacks, 0, sizeof callbacks);
  callbacks.new_sample = pm_frame_new_sample;
  callbacks.new_preroll = pm_frame_new_preroll;
  gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, target, g_free);
  return sink;
}

#endif
