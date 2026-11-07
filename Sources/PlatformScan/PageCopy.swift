import Foundation

#if canImport(CoreText) && canImport(ImageIO)
  import CoreGraphics
  import CoreText
  import ImageIO
#endif

/// A copy of a document to give someone: a PDF of its pages with parts blacked out and a watermark across each page.
/// Both are drawn into the pictures themselves, so the PDF holds nothing under a black box and the watermark can't be
/// lifted off; the copy has no text layer. Core Graphics on Apple platforms; not on Linux or Windows yet.
///
/// ```swift
/// let pdf = try PageCopy.pdf([.init(image: page, hidden: [numberBox])], watermark: "Copy for Acme Lettings · 7 Nov 2026")
/// ```
public nonisolated enum PageCopy {
  public struct Page: Sendable {
    /// The page as an image (JPEG, PNG, HEIC).
    public var image: Data
    /// Parts filled black.
    public var hidden: [PageRect]

    public init(image: Data, hidden: [PageRect] = []) {
      self.image = image
      self.hidden = hidden
    }
  }

  public static var isAvailable: Bool {
    #if canImport(CoreText) && canImport(ImageIO)
      true
    #else
      false
    #endif
  }

  /// The pages as a PDF, each page as wide as A4 (595 points) and as tall as its picture needs.
  public static func pdf(
    _ pages: [Page], watermark: String? = nil, title: String? = nil, maxPixel: Int = 2400, quality: Double = 0.8
  ) throws -> Data {
    #if canImport(CoreText) && canImport(ImageIO)
      let output = NSMutableData()
      guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw ScanError("no PDF consumer") }
      var info: [CFString: Any] = [kCGPDFContextCreator: "v57 Vault"]
      if let title { info[kCGPDFContextTitle] = title }
      var media = CGRect(x: 0, y: 0, width: 595, height: 842)
      guard let pdf = CGContext(consumer: consumer, mediaBox: &media, info as CFDictionary) else {
        throw ScanError("no PDF context")
      }
      for page in pages {
        let image = try burned(page, watermark: watermark, maxPixel: maxPixel, quality: quality)
        let height = 595 * CGFloat(image.height) / CGFloat(image.width)
        var box = CGRect(x: 0, y: 0, width: 595, height: height)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        pdf.beginPDFPage([kCGPDFContextMediaBox: boxData as CFData] as CFDictionary)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
      }
      pdf.closePDF()
      return output as Data
    #else
      throw ScanError.unsupported
    #endif
  }

  #if canImport(CoreText) && canImport(ImageIO)
    /// The page's picture with the boxes and the watermark drawn in, re-read from JPEG so the PDF keeps it as JPEG.
    static func burned(_ page: Page, watermark: String?, maxPixel: Int, quality: Double) throws -> CGImage {
      guard let source = CGImageSourceCreateWithData(page.image as CFData, nil) else { throw ScanError.notAnImage }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let original = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ScanError.notAnImage
      }
      let width = original.width, height = original.height
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw ScanError("no bitmap context") }
      let size = CGSize(width: width, height: height)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(origin: .zero, size: size))
      context.draw(original, in: CGRect(origin: .zero, size: size))

      context.setFillColor(CGColor(gray: 0, alpha: 1))
      for rect in page.hidden {
        context.fill(
          CGRect(
            x: rect.x * size.width, y: (1 - rect.maxY) * size.height, width: rect.width * size.width,
            height: rect.height * size.height
          ).integral)
      }
      if let watermark, !watermark.isEmpty { drawWatermark(watermark, in: context, size: size) }

      guard let drawn = context.makeImage(), let jpeg = PageScanner.jpeg(drawn, quality: quality),
        let reread = CGImageSourceCreateWithData(jpeg.data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(reread, 0, nil)
      else { throw ScanError("the page couldn't be drawn") }
      return image
    }

    /// The text in rows across the page at 30°, grey and see-through, so no part of the page is clear of it.
    static func drawWatermark(_ text: String, in context: CGContext, size: CGSize) {
      let fontSize = max(14, min(size.width, size.height) / 24)
      let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
      let attributes: [CFString: Any] = [
        kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0.45, green: 0.1, blue: 0.1, alpha: 0.28),
      ]
      let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, ("   " + text + "   ") as CFString, attributes as CFDictionary))
      let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
      guard lineWidth > 0 else { return }
      context.saveGState()
      context.translateBy(x: size.width / 2, y: size.height / 2)
      context.rotate(by: .pi / 6)
      let reach = hypot(size.width, size.height) / 2
      let step = fontSize * 4.5
      var row = -reach
      var shift = 0.0
      while row <= reach {
        var x = -reach - lineWidth + shift
        while x <= reach {
          context.textPosition = CGPoint(x: x, y: row)
          CTLineDraw(line, context)
          x += lineWidth
        }
        row += step
        shift = shift == 0 ? lineWidth / 2 : 0
      }
      context.restoreGState()
    }
  #endif
}
