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

  @Test func writesPNGAndJPEG() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // 3 x 2: red, green, blue on top; a half-transparent white and two opaque greys below.
    let bitmap = Bitmap(width: 3, height: 2, rgba: [
      255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
      128, 128, 128, 128, 90, 90, 90, 255, 200, 200, 200, 255,
    ])
    let png = folder.appendingPathComponent("a.png")
    try ImageFile.write(bitmap, to: png)
    let back = try #require(ImageFile.load(at: png))
    #expect(back.width == 3 && back.height == 2)
    #expect(Array(back.rgba[0..<12]) == Array(bitmap.rgba[0..<12]))
    #expect(abs(Int(back.rgba[15]) - 128) <= 1)
    let jpeg = folder.appendingPathComponent("a.jpg")
    try ImageFile.write(bitmap, to: jpeg, format: .jpeg(quality: 0.9))
    #expect(ImageFile.pixelSize(at: jpeg)! == (3, 2))
    #expect(throws: ImageFileError.self) { try ImageFile.write(Bitmap(width: 0, height: 0, rgba: []), to: png) }
  }
}
