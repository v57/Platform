import Foundation

#if canImport(Vision) && canImport(CoreImage)
  import CoreGraphics
  import CoreImage
  import ImageIO
  import UniformTypeIdentifiers
  import Vision
#endif

/// Reading photographed and scanned pages on the device: their text, where the page's corners are, and the page
/// straightened and cleaned up. Vision and Core Image on Apple platforms; not on Linux or Windows yet
/// (`isAvailable` says so). Nothing leaves the device.
///
/// ```swift
/// let quad = try await PageScanner.edges(in: photo) ?? .full
/// let page = try PageScanner.straighten(photo, quad: quad, look: .document)
/// let lines = try await PageScanner.lines(in: page.data)
/// ```
public nonisolated enum PageScanner {
  public static var isAvailable: Bool {
    #if canImport(Vision) && canImport(CoreImage)
      true
    #else
      false
    #endif
  }

  /// The page's lines of text, top to bottom. Language correction is off: names, numbers and machine-readable zones
  /// come through as printed.
  public static func lines(in image: Data) async throws -> [PageTextLine] {
    #if canImport(Vision) && canImport(CoreImage)
      try await offPool {
        let cgImage = try decode(image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if #available(macOS 13, iOS 16, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> PageTextLine? in
          guard let best = observation.topCandidates(1).first else { return nil }
          let box = observation.boundingBox
          return PageTextLine(
            text: best.string,
            box: PageRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
            confidence: Double(best.confidence))
        }
        return joinedRows(sortedInReadingOrder(lines))
      }
    #else
      throw ScanError.unsupported
    #endif
  }

  /// The text of each line, for `DocumentReader` and search.
  public static func text(in image: Data) async throws -> [String] {
    try await lines(in: image).map(\.text)
  }

  /// Lines top to bottom; lines whose middles are on one row, left to right.
  static func sortedInReadingOrder(_ lines: [PageTextLine]) -> [PageTextLine] {
    lines.sorted { a, b in
      let rowA = a.box.y + a.box.height / 2, rowB = b.box.y + b.box.height / 2
      if abs(rowA - rowB) < min(a.box.height, b.box.height) / 2 { return a.box.x < b.box.x }
      return rowA < rowB
    }
  }

  /// Pieces of one printed line read as several (a machine-readable zone's long `<<<` runs): pieces on one row with
  /// less than half a line's height between them become one line. Columns further apart stay apart.
  static func joinedRows(_ lines: [PageTextLine]) -> [PageTextLine] {
    var result: [PageTextLine] = []
    for line in lines {
      if let previous = result.last {
        let height = min(previous.box.height, line.box.height)
        let sameRow = abs((previous.box.y + previous.box.height / 2) - (line.box.y + line.box.height / 2)) < height / 2
        let gap = line.box.x - (previous.box.x + previous.box.width)
        if sameRow, gap > -height, gap < height / 2 {
          let union = previous.box.union(line.box)
          result[result.count - 1] = PageTextLine(
            text: previous.text + (gap > height / 4 ? " " : "") + line.text, box: union,
            confidence: min(previous.confidence, line.confidence))
          continue
        }
      }
      result.append(line)
    }
    return result
  }

  /// Where the page's corners are in a photo, nil when no page stands out.
  public static func edges(in image: Data) async throws -> PageQuad? {
    #if canImport(Vision) && canImport(CoreImage)
      try await offPool {
        let cgImage = try decode(image)
        let handler = VNImageRequestHandler(cgImage: cgImage)
        let segmentation = VNDetectDocumentSegmentationRequest()
        try handler.perform([segmentation])
        if let found = segmentation.results?.first, found.confidence > 0.5 { return quad(found) }
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.3
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumObservations = 1
        try handler.perform([rectangles])
        return rectangles.results?.first.map(quad)
      }
    #else
      throw ScanError.unsupported
    #endif
  }

  /// The page inside `quad` as a flat rectangle, its longer side at most `maxPixel`, as JPEG.
  public static func straighten(
    _ image: Data, quad: PageQuad = .full, look: PageLook = .color, maxPixel: Int = 3000, quality: Double = 0.8
  ) throws -> PageImage {
    #if canImport(Vision) && canImport(CoreImage)
      guard var picture = CIImage(data: image, options: [.applyOrientationProperty: true]) else {
        throw ScanError.notAnImage
      }
      picture = picture.transformed(
        by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
      let size = picture.extent.size
      func point(_ p: PagePoint) -> CIVector { CIVector(x: p.x * size.width, y: (1 - p.y) * size.height) }
      if quad != .full {
        picture = picture.applyingFilter(
          "CIPerspectiveCorrection",
          parameters: [
            "inputTopLeft": point(quad.topLeft), "inputTopRight": point(quad.topRight),
            "inputBottomRight": point(quad.bottomRight), "inputBottomLeft": point(quad.bottomLeft),
          ])
      }
      switch look {
      case .color: break
      case .grayscale:
        picture = picture.applyingFilter(
          "CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15])
      case .document:
        if let enhancer = CIFilter(name: "CIDocumentEnhancer") {
          enhancer.setValue(picture, forKey: kCIInputImageKey)
          enhancer.setValue(1, forKey: "inputAmount")
          picture = enhancer.outputImage ?? picture
        } else {
          picture = picture.applyingFilter(
            "CIColorControls", parameters: [kCIInputSaturationKey: 0.2, kCIInputContrastKey: 1.3])
        }
      }
      let longer = max(picture.extent.width, picture.extent.height)
      if longer > CGFloat(maxPixel) {
        let scale = CGFloat(maxPixel) / longer
        picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
      }
      picture = picture.cropped(to: picture.extent.integral)
      return try encode(picture, quality: quality)
    #else
      throw ScanError.unsupported
    #endif
  }

  /// The picture scaled down to `maxPixel` on its longer side, as JPEG: a document's thumbnail.
  public static func thumbnail(of image: Data, maxPixel: Int = 480, quality: Double = 0.7) -> PageImage? {
    #if canImport(Vision) && canImport(CoreImage)
      guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return jpeg(thumbnail, quality: quality)
    #else
      return nil
    #endif
  }

  /// An image's size in pixels with its orientation applied.
  public static func pixelSize(of image: Data) -> (width: Int, height: Int)? {
    #if canImport(Vision) && canImport(CoreImage)
      guard let source = CGImageSourceCreateWithData(image as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
      else { return nil }
      let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
      return orientation >= 5 ? (height, width) : (width, height)
    #else
      return nil
    #endif
  }

  #if canImport(Vision) && canImport(CoreImage)
    /// A picture the app drew (a rendered view) as a JPEG page.
    public static func page(from image: CGImage, quality: Double = 0.85) -> PageImage? {
      jpeg(image, quality: quality)
    }

    /// Vision's requests block their thread, the first text request in an app for many seconds (the Neural Engine
    /// compiles its model), so they run on a Dispatch queue rather than holding a thread of Swift's cooperative pool.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
      try await withCheckedThrowingContinuation { continuation in
        visionQueue.async { continuation.resume(with: Result { try work() }) }
      }
    }

    private static let visionQueue = DispatchQueue(label: "PlatformScan.vision", qos: .userInitiated, attributes: .concurrent)

    static let context = CIContext(options: [.cacheIntermediates: false])

    static func decode(_ data: Data) throws -> CGImage {
      guard let picture = CIImage(data: data, options: [.applyOrientationProperty: true]),
        let image = context.createCGImage(picture, from: picture.extent)
      else { throw ScanError.notAnImage }
      return image
    }

    private static func quad(_ observation: VNRectangleObservation) -> PageQuad {
      func point(_ p: CGPoint) -> PagePoint { PagePoint(x: p.x, y: 1 - p.y) }
      return PageQuad(
        topLeft: point(observation.topLeft), topRight: point(observation.topRight),
        bottomRight: point(observation.bottomRight), bottomLeft: point(observation.bottomLeft))
    }

    private static func encode(_ picture: CIImage, quality: Double) throws -> PageImage {
      guard let image = context.createCGImage(picture, from: picture.extent), let page = jpeg(image, quality: quality)
      else { throw ScanError("the page couldn't be made into an image") }
      return page
    }

    static func jpeg(_ image: CGImage, quality: Double) -> PageImage? {
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return PageImage(data: output as Data, width: image.width, height: image.height)
    }
  #endif
}
