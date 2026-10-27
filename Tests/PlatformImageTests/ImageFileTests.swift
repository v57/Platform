import Foundation
import PlatformImage
import Testing

@Suite struct ImageFileTests {
  /// A 2 x 1 PNG: one opaque red pixel, one transparent.
  static let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR4nGP4z8AARAwMAAz8Af9c/RSVAAAAAElFTkSuQmCC")!

  @Test func readsSizeAndPixels() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString).png")
    try Self.png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(ImageFile.pixelSize(at: url)! == (2, 1))
    let bitmap = try #require(ImageFile.load(at: url))
    #expect(bitmap.width == 2 && bitmap.height == 1)
    #expect(Array(bitmap.rgba[0..<4]) == [255, 0, 0, 255])
    #expect(bitmap.rgba[7] == 0)
    #expect(ImageFile.pixelSize(at: url.deletingPathExtension()) == nil)
  }
}
