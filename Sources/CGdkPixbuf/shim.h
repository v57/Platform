// GdkPixbuf: image files (PNG, JPEG, WebP, ...) on Linux, for PlatformImage.
#include <gdk-pixbuf/gdk-pixbuf.h>

// Saves without gdk_pixbuf_save's varargs, which Swift can't call: PNG, or JPEG with a quality ("0"–"100").
static inline gboolean platform_pixbuf_save(GdkPixbuf *pixbuf, const char *path, const char *type, const char *quality, GError **error) {
  if (quality) {
    char *keys[] = {"quality", NULL};
    char *values[] = {(char *)quality, NULL};
    return gdk_pixbuf_savev(pixbuf, path, type, keys, values, error);
  }
  return gdk_pixbuf_savev(pixbuf, path, type, NULL, NULL, error);
}
