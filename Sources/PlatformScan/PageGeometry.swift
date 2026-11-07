import Foundation

/// A point on a page, 0...1 across and down from the top left corner, whatever the image's size.
public struct PagePoint: Hashable, Sendable, Codable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// A rectangle on a page in the same units as `PagePoint`.
public struct PageRect: Hashable, Sendable, Codable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Double { x + width }
  public var maxY: Double { y + height }

  /// The smallest rectangle around both.
  public func union(_ other: PageRect) -> PageRect {
    let left = min(x, other.x), top = min(y, other.y)
    return PageRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
  }
}

/// A page's four corners in a photo, for straightening it.
public struct PageQuad: Hashable, Sendable, Codable {
  public var topLeft: PagePoint
  public var topRight: PagePoint
  public var bottomRight: PagePoint
  public var bottomLeft: PagePoint

  public init(topLeft: PagePoint, topRight: PagePoint, bottomRight: PagePoint, bottomLeft: PagePoint) {
    self.topLeft = topLeft
    self.topRight = topRight
    self.bottomRight = bottomRight
    self.bottomLeft = bottomLeft
  }

  /// The whole image.
  public static let full = PageQuad(
    topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 0), bottomRight: .init(x: 1, y: 1),
    bottomLeft: .init(x: 0, y: 1))

  public var corners: [PagePoint] { [topLeft, topRight, bottomRight, bottomLeft] }
}

/// One line of text read from a page.
public struct PageTextLine: Hashable, Sendable {
  public var text: String
  public var box: PageRect
  /// 0...1.
  public var confidence: Double

  public init(text: String, box: PageRect, confidence: Double) {
    self.text = text
    self.box = box
    self.confidence = confidence
  }
}

/// How a straightened page looks.
public enum PageLook: String, Hashable, Sendable, Codable, CaseIterable {
  /// As photographed.
  case color
  /// Grey, a little more contrast.
  case grayscale
  /// White paper and dark ink, shadows lifted: the system's document filter where it has one.
  case document
}

/// An image made here: JPEG data and its size in pixels.
public struct PageImage: Hashable, Sendable {
  public var data: Data
  public var width: Int
  public var height: Int
  public var contentType: String

  public init(data: Data, width: Int, height: Int, contentType: String = "image/jpeg") {
    self.data = data
    self.width = width
    self.height = height
    self.contentType = contentType
  }
}

public struct ScanError: Error, CustomStringConvertible, Sendable {
  public var description: String
  public init(_ description: String) { self.description = description }

  static let unsupported = ScanError("this system can't read pages yet")
  static let notAnImage = ScanError("the file isn't an image")
}
