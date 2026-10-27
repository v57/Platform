import Foundation

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#elseif os(Linux)
  import CGdkPixbuf
#endif

/// Decoded pixels: RGBA, 8 bits a channel, premultiplied by alpha, sRGB, rows top to bottom with no padding — what a
/// `CGImage` with `premultipliedLast` takes as it is.
public struct Bitmap: Sendable {
  public let width: Int
  public let height: Int
  public let rgba: [UInt8]

  public init(width: Int, height: Int, rgba: [UInt8]) {
    self.width = width
    self.height = height
    self.rgba = rgba
  }

  public var bytesPerRow: Int { width * 4 }
}

/// Image files (PNG, JPEG, HEIC on Apple platforms, WebP where the system reads it) without the platform's image
/// types: their pixel size and their pictures scaled down for display. ImageIO on Apple platforms, GdkPixbuf on Linux.
///
/// ```swift
/// if let picture = ImageFile.thumbnail(at: url, maxPixel: 600) { … picture.width, picture.rgba … }
/// ```
public nonisolated enum ImageFile {
  /// The picture's size in pixels, read from its header; nil when the file isn't an image.
  public static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
    #if canImport(ImageIO)
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
      else { return nil }
      return (width, height)
    #elseif os(Linux)
      var width: Int32 = 0
      var height: Int32 = 0
      guard gdk_pixbuf_get_file_info(url.path, &width, &height) != nil else { return nil }
      return (Int(width), Int(height))
    #else
      return nil
    #endif
  }

  /// The picture, its longer side at most `maxPixel` (never scaled up), with its orientation applied.
  public static func thumbnail(at url: URL, maxPixel: Int) -> Bitmap? {
    #if canImport(ImageIO)
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return bitmap(of: image)
    #elseif os(Linux)
      guard let (width, height) = pixelSize(at: url), width > 0, height > 0 else { return nil }
      let scale = min(1, Double(maxPixel) / Double(max(width, height)))
      var error: UnsafeMutablePointer<GError>?
      guard
        let pixbuf = gdk_pixbuf_new_from_file_at_scale(
          url.path, Int32(max(1, (Double(width) * scale).rounded())), Int32(max(1, (Double(height) * scale).rounded())),
          1, &error)
      else {
        if let error { g_error_free(error) }
        return nil
      }
      defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
      let oriented = gdk_pixbuf_apply_embedded_orientation(pixbuf) ?? pixbuf
      defer { if oriented != pixbuf { g_object_unref(UnsafeMutableRawPointer(oriented)) } }
      return bitmap(of: oriented)
    #else
      return nil
    #endif
  }

  /// The whole picture at its own size.
  public static func load(at url: URL) -> Bitmap? {
    guard let size = pixelSize(at: url) else { return nil }
    return thumbnail(at: url, maxPixel: max(size.width, size.height))
  }

  #if canImport(ImageIO)
    private static func bitmap(of image: CGImage) -> Bitmap? {
      let width = image.width
      let height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      return drawn ? Bitmap(width: width, height: height, rgba: pixels) : nil
    }
  #elseif os(Linux)
    private static func bitmap(of pixbuf: OpaquePointer) -> Bitmap? {
      let width = Int(gdk_pixbuf_get_width(pixbuf))
      let height = Int(gdk_pixbuf_get_height(pixbuf))
      let stride = Int(gdk_pixbuf_get_rowstride(pixbuf))
      let channels = Int(gdk_pixbuf_get_n_channels(pixbuf))
      let alpha = gdk_pixbuf_get_has_alpha(pixbuf) != 0
      guard channels >= 3, let source = gdk_pixbuf_read_pixels(pixbuf) else { return nil }
      var pixels = [UInt8](repeating: 255, count: width * height * 4)
      for y in 0..<height {
        for x in 0..<width {
          let from = y * stride + x * channels
          let to = (y * width + x) * 4
          let a = alpha ? Int(source[from + 3]) : 255
          for c in 0..<3 { pixels[to + c] = UInt8((Int(source[from + c]) * a + 127) / 255) }
          pixels[to + 3] = UInt8(a)
        }
      }
      return Bitmap(width: width, height: height, rgba: pixels)
    }
  #endif
}
