import Foundation
import Testing

@testable import PlatformScan

/// What every platform does: lines put in reading order and pieces of one printed line joined, and on platforms with
/// no reader yet, each call saying so.
struct ScanLogicTests {
  @Test func readingOrderKeepsARowLeftToRight() {
    let right = PageTextLine(text: "B", box: PageRect(x: 0.6, y: 0.1, width: 0.2, height: 0.05), confidence: 1)
    let left = PageTextLine(text: "A", box: PageRect(x: 0.1, y: 0.11, width: 0.2, height: 0.05), confidence: 1)
    let below = PageTextLine(text: "C", box: PageRect(x: 0.1, y: 0.3, width: 0.2, height: 0.05), confidence: 1)
    #expect(PageScanner.sortedInReadingOrder([below, right, left]).map(\.text) == ["A", "B", "C"])
  }

  @Test func piecesOfOneLineAreJoinedButColumnsStayApart() {
    let a = PageTextLine(text: "TR1029384<", box: PageRect(x: 0.1, y: 0.8, width: 0.4, height: 0.04), confidence: 0.9)
    let b = PageTextLine(text: "<<<<<<<", box: PageRect(x: 0.505, y: 0.801, width: 0.2, height: 0.04), confidence: 0.6)
    let c = PageTextLine(text: "<<<<<04", box: PageRect(x: 0.71, y: 0.8, width: 0.2, height: 0.04), confidence: 1)
    let label = PageTextLine(text: "Holder", box: PageRect(x: 0.1, y: 0.2, width: 0.1, height: 0.04), confidence: 1)
    let value = PageTextLine(text: "Aiko", box: PageRect(x: 0.6, y: 0.2, width: 0.1, height: 0.04), confidence: 1)
    let joined = PageScanner.joinedRows(PageScanner.sortedInReadingOrder([c, a, value, b, label]))
    #expect(joined.map(\.text) == ["Holder", "Aiko", "TR1029384<<<<<<<<<<<<<04"])
    #expect(joined[2].confidence == 0.6)
    #expect(abs(joined[2].box.width - 0.81) < 0.001)
  }

  #if !canImport(Vision)
    @Test func withoutAReaderEachCallSaysSo() async throws {
      #expect(!PageScanner.isAvailable && !PDFPages.isAvailable)
      await #expect(throws: ScanError.self) { try await PageScanner.lines(in: Data([1, 2, 3])) }
      #expect(throws: ScanError.self) { try PageScanner.straighten(Data([1, 2, 3])) }
      #expect(PageScanner.thumbnail(of: Data([1, 2, 3])) == nil)
      #expect(PDFPages.isPDF(Data("%PDF-1.7".utf8)))
      #expect(PDFPages.pageCount(Data("%PDF-1.7".utf8)) == nil)
    }
  #endif
}

#if canImport(CoreText) && canImport(ImageIO) && canImport(Vision)
  import CoreGraphics
  import CoreText
  import ImageIO

  /// A white page on a dark table, with lines of black text: what a photo of a document looks like to the reader.
  func photo(lines: [String], width: Int = 1600, height: Int = 1200, page: CGRect? = nil) -> Data {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let paper = page ?? CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(paper)
    let font = CTFontCreateWithName("Courier-Bold" as CFString, paper.width / 28, nil)
    for (index, text) in lines.enumerated() {
      let string = CFAttributedStringCreate(
        nil, text as CFString,
        [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary)!
      context.textPosition = CGPoint(
        x: paper.minX + paper.width * 0.06, y: paper.maxY - paper.height * 0.15 - CGFloat(index) * paper.width / 18)
      CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    return PageScanner.jpeg(context.makeImage()!, quality: 0.92)!.data
  }

  func pixel(_ jpeg: Data, x: Double, y: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(
      image,
      in: CGRect(
        x: -x * Double(image.width), y: -(1 - y) * Double(image.height) + 1, width: Double(image.width),
        height: Double(image.height)))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    return (bytes[0], bytes[1], bytes[2])
  }

  struct PageScannerTests {
    @Test func readsLinesTopToBottom() async throws {
      let image = photo(lines: ["PASSPORT", "DATE OF EXPIRY 12.03.2032", "TANAKA AIKO"])
      let lines = try await PageScanner.lines(in: image)
      let text = lines.map(\.text)
      #expect(text.count == 3)
      #expect(text.first == "PASSPORT")
      #expect(text.contains { $0.contains("12.03.2032") })
      #expect(lines.allSatisfy { $0.box.y >= 0 && $0.box.maxY <= 1 })
      #expect(lines[0].box.y < lines[2].box.y)
    }

    @Test func findsThePageAndStraightensIt() async throws {
      let image = photo(
        lines: ["RENTAL AGREEMENT", "LANDLORD"], width: 1600, height: 1200,
        page: CGRect(x: 400, y: 150, width: 800, height: 900))
      let quad = try #require(try await PageScanner.edges(in: image))
      #expect(abs(quad.topLeft.x - 0.25) < 0.05)
      #expect(abs(quad.topLeft.y - 0.125) < 0.05)
      #expect(abs(quad.bottomRight.x - 0.75) < 0.05)
      #expect(abs(quad.bottomRight.y - 0.875) < 0.05)

      let page = try PageScanner.straighten(image, quad: quad, look: .document, maxPixel: 1000)
      #expect(max(page.width, page.height) <= 1000)
      #expect(abs(Double(page.width) / Double(page.height) - 800.0 / 900.0) < 0.08)
      // The table around the page is gone: the corners are paper.
      #expect(pixel(page.data, x: 0.02, y: 0.02).r > 180)
      #expect(pixel(page.data, x: 0.98, y: 0.98).r > 180)
    }

    @Test func thumbnailAndSize() throws {
      let image = photo(lines: ["X"], width: 1600, height: 1200)
      #expect(PageScanner.pixelSize(of: image)! == (1600, 1200))
      let thumbnail = try #require(PageScanner.thumbnail(of: image, maxPixel: 400))
      #expect(thumbnail.width == 400 && thumbnail.height == 300)
      #expect(PageScanner.thumbnail(of: Data("not an image".utf8), maxPixel: 400) == nil)
      #expect(throws: ScanError.self) { try PageScanner.straighten(Data([1, 2, 3])) }
    }
  }

  struct PageCopyTests {
    @Test func hiddenPartsAreBlackInThePixels() throws {
      let image = photo(lines: ["NUMBER TR4821", "NAME AIKO"], width: 800, height: 1000)
      let hidden = PageRect(x: 0.5, y: 0.4, width: 0.3, height: 0.2)
      let pdf = try PageCopy.pdf(
        [.init(image: image, hidden: [hidden]), .init(image: image)], watermark: "Copy for Acme · 7 Nov 2026",
        title: "Passport")
      #expect(PDFPages.isPDF(pdf))
      #expect(PDFPages.pageCount(pdf) == 2)
      // No text layer: the copy can't be searched for what was on it.
      #expect(PDFPages.text(pdf).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      let size = try #require(PDFPages.pageSize(pdf))
      #expect(abs(size.width - 595) < 1 && abs(size.height - 595 * 1000 / 800) < 1)

      let first = try #require(PDFPages.render(pdf, page: 0, maxPixel: 1000))
      let inside = pixel(first.data, x: 0.65, y: 0.5)
      #expect(inside.r < 30 && inside.g < 30 && inside.b < 30)
      let second = try #require(PDFPages.render(pdf, page: 1, maxPixel: 1000))
      #expect(pixel(second.data, x: 0.65, y: 0.5).r > 150)
    }

    @Test func watermarkCoversThePage() throws {
      let blank = photo(lines: [], width: 800, height: 800)
      let pdf = try PageCopy.pdf([.init(image: blank)], watermark: "Copy for Acme Lettings")
      let page = try #require(PDFPages.render(pdf, maxPixel: 400))
      // Rows of watermark in every part of the page: each quarter has tinted pixels.
      let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(page.data as CFData, nil)!, 0, nil)!
      let width = image.width, height = image.height
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
      for (qx, qy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        var tinted = 0
        for y in (qy * height / 2)..<((qy + 1) * height / 2) {
          for x in (qx * width / 2)..<((qx + 1) * width / 2) {
            let index = (y * width + x) * 4
            if Int(bytes[index]) - Int(bytes[index + 2]) > 20 { tinted += 1 }
          }
        }
        #expect(tinted > 200, "quarter \(qx),\(qy) has \(tinted) tinted pixels")
      }
    }
  }

  struct PDFPagesTests {
    @Test func textAndPages() throws {
      let output = NSMutableData()
      var media = CGRect(x: 0, y: 0, width: 595, height: 842)
      let context = CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &media, nil)!
      for text in ["Policy schedule", "Renewal date 01.02.2027"] {
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
          CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!)
        context.textPosition = CGPoint(x: 72, y: 760)
        CTLineDraw(line, context)
        context.endPDFPage()
      }
      context.closePDF()
      let pdf = output as Data

      #expect(PDFPages.pageCount(pdf) == 2)
      let text = PDFPages.text(pdf)
      #expect(text[0].contains("Policy schedule"))
      #expect(text[1].contains("01.02.2027"))
      let page = try #require(PDFPages.render(pdf, page: 1, maxPixel: 842))
      #expect(page.height == 842 && page.width == 595)
      #expect(PDFPages.render(pdf, page: 5) == nil)
      #expect(PDFPages.pageCount(Data("no".utf8)) == nil)
    }
  }
#endif
