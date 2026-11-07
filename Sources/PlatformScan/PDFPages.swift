import Foundation

#if canImport(PDFKit) && canImport(CoreImage)
  import CoreGraphics
  import PDFKit
#endif

/// An imported PDF's pages: how many, their text and their pictures. PDFKit and Core Graphics on Apple platforms;
/// nothing on Linux or Windows yet (`isAvailable`).
public nonisolated enum PDFPages {
  public static var isAvailable: Bool {
    #if canImport(PDFKit) && canImport(CoreImage)
      true
    #else
      false
    #endif
  }

  /// Whether the data starts like a PDF.
  public static func isPDF(_ data: Data) -> Bool { data.prefix(5) == Data("%PDF-".utf8) }

  /// The number of pages, nil when it isn't a PDF this system opens (or it's locked).
  public static func pageCount(_ data: Data) -> Int? {
    #if canImport(PDFKit) && canImport(CoreImage)
      guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
      return document.pageCount
    #else
      return nil
    #endif
  }

  /// The text of each page (empty for a scanned page without a text layer).
  public static func text(_ data: Data) -> [String] {
    #if canImport(PDFKit) && canImport(CoreImage)
      guard let document = PDFDocument(data: data), !document.isLocked else { return [] }
      return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    #else
      return []
    #endif
  }

  /// The size of a page in points (its crop box, rotation applied).
  public static func pageSize(_ data: Data, page: Int = 0) -> (width: Double, height: Double)? {
    #if canImport(PDFKit) && canImport(CoreImage)
      guard let document = CGPDFDocument(CGDataProvider(data: data as CFData)!), let pdfPage = document.page(at: page + 1)
      else { return nil }
      let box = pdfPage.getBoxRect(.cropBox)
      return pdfPage.rotationAngle % 180 == 0 ? (box.width, box.height) : (box.height, box.width)
    #else
      return nil
    #endif
  }

  /// A page (from 0) drawn on white, its longer side `maxPixel`, as JPEG: for thumbnails, the viewer and copies.
  public static func render(_ data: Data, page: Int = 0, maxPixel: Int = 2000, quality: Double = 0.85) -> PageImage? {
    #if canImport(PDFKit) && canImport(CoreImage)
      guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
        let pdfPage = document.page(at: page + 1)
      else { return nil }
      let box = pdfPage.getBoxRect(.cropBox)
      let rotated = pdfPage.rotationAngle % 180 != 0
      let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
      guard size.width > 0, size.height > 0 else { return nil }
      let scale = CGFloat(maxPixel) / max(size.width, size.height)
      let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.interpolationQuality = .high
      let target = CGRect(x: 0, y: 0, width: width, height: height)
      context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
      context.drawPDFPage(pdfPage)
      guard let image = context.makeImage() else { return nil }
      return PageScanner.jpeg(image, quality: quality)
    #else
      return nil
    #endif
  }
}
