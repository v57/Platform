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

/// The kinds of file `ImageFile.write` makes.
public enum ImageFileFormat: Sendable, Hashable {
  case png
  /// Quality 0...1.
  case jpeg(quality: Double)
}

public struct ImageFileError: Error, CustomStringConvertible, Sendable {
  public var description: String
  public init(_ description: String) { self.description = description }
}

/// Image files (PNG, JPEG, HEIC on Apple platforms, WebP where the system reads it) without the platform's image
/// types: their pixel size, their pictures scaled down for display, and pictures written as PNG or JPEG. ImageIO on
/// Apple platforms, GdkPixbuf on Linux.
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

  /// Writes `bitmap` as a PNG or JPEG file at `url`, replacing what's there.
  public static func write(_ bitmap: Bitmap, to url: URL, format: ImageFileFormat = .png) throws {
    guard bitmap.width > 0, bitmap.height > 0, bitmap.rgba.count == bitmap.width * bitmap.height * 4 else {
      throw ImageFileError("The picture has no pixels.")
    }
    #if canImport(ImageIO)
      let data = Data(bitmap.rgba) as CFData
      guard let provider = CGDataProvider(data: data),
        let image = CGImage(
          width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: bitmap.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
          decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { throw ImageFileError("The picture couldn't be made.") }
      let type: CFString
      var options: [CFString: Any] = [:]
      switch format {
      case .png: type = "public.png" as CFString
      case .jpeg(let quality):
        type = "public.jpeg" as CFString
        options[kCGImageDestinationLossyCompressionQuality] = quality
      }
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw ImageFileError("Can't write \(url.lastPathComponent).")
      }
      CGImageDestinationAddImage(destination, image, options as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw ImageFileError("Can't write \(url.lastPathComponent).") }
    #elseif os(Linux)
      // GdkPixbuf takes straight (not premultiplied) alpha.
      var pixels = bitmap.rgba
      for index in stride(from: 0, to: pixels.count, by: 4) {
        let a = Int(pixels[index + 3])
        guard a > 0, a < 255 else { continue }
        for c in 0..<3 { pixels[index + c] = UInt8(min(255, (Int(pixels[index + c]) * 255 + a / 2) / a)) }
      }
      try pixels.withUnsafeMutableBufferPointer { buffer in
        guard
          let pixbuf = gdk_pixbuf_new_from_data(
            buffer.baseAddress, GDK_COLORSPACE_RGB, 1, 8, Int32(bitmap.width), Int32(bitmap.height),
            Int32(bitmap.bytesPerRow), nil, nil)
        else { throw ImageFileError("The picture couldn't be made.") }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        var error: UnsafeMutablePointer<GError>?
        let saved: gboolean
        switch format {
        case .png:
          saved = platform_pixbuf_save(pixbuf, url.path, "png", nil, &error)
        case .jpeg(let quality):
          // JPEG has no alpha: GdkPixbuf drops it.
          let value = String(Int((quality * 100).rounded()))
          saved = platform_pixbuf_save(pixbuf, url.path, "jpeg", value, &error)
        }
        if let error {
          let message = String(cString: error.pointee.message)
          g_error_free(error)
          throw ImageFileError(message)
        }
        guard saved != 0 else { throw ImageFileError("Can't write \(url.lastPathComponent).") }
      }
    #else
      throw ImageFileError("Writing pictures isn't available here.")
    #endif
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
