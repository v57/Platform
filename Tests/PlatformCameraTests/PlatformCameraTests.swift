import Foundation
import Testing

@testable import PlatformCamera

@Suite struct MotionDetectorTests {
  /// A 64×36 grid of one brightness with a lighter square of `size` cells at `x`, `y`
  func grid(base: UInt8 = 80, square size: Int = 0, x: Int = 10, y: Int = 10, value: UInt8 = 200) -> [UInt8] {
    var grid = [UInt8](repeating: base, count: 64 * 36)
    for row in y..<min(36, y + size) {
      for column in x..<min(64, x + size) { grid[row * 64 + column] = value }
    }
    return grid
  }

  @Test func stillPictureHasNoMotion() {
    var detector = MotionDetector(sensitivity: 1)
    for frame in 0..<50 {
      #expect(detector.process(luma: grid(), columns: 64, time: Double(frame) / 5) == nil)
    }
    #expect(!detector.isActive)
  }

  @Test func movingSquareStartsThenEndsMotion() {
    var detector = MotionDetector(sensitivity: 0.5, cooldown: 2, framesToStart: 2)
    var time = 0.0
    for _ in 0..<10 {
      _ = detector.process(luma: grid(), columns: 64, time: time)
      time += 0.2
    }
    var events = [MotionEvent]()
    // A 6×6 square (1.6% of the picture) moving across
    for step in 0..<10 {
      if let event = detector.process(luma: grid(square: 6, x: 5 + step * 4), columns: 64, time: time) { events.append(event) }
      time += 0.2
    }
    #expect(events.map(\.isActive) == [true])
    #expect(detector.isActive)
    // Where it stops, it becomes background within seconds, then motion ends after the cooldown
    for _ in 0..<60 {
      if let event = detector.process(luma: grid(square: 6, x: 45), columns: 64, time: time) { events.append(event) }
      time += 0.2
    }
    #expect(events.map(\.isActive) == [true, false])
  }

  @Test func sensitivityDecidesSmallMotion() {
    // A 3×3 square: 0.4% of the picture
    func detects(_ sensitivity: Double) -> Bool {
      var detector = MotionDetector(sensitivity: sensitivity)
      _ = detector.process(luma: grid(), columns: 64, time: 0)
      var started = false
      for step in 0..<6 where detector.process(luma: grid(square: 3, x: 5 + step * 4), columns: 64, time: 0.2 * Double(step + 1))?.isActive == true {
        started = true
      }
      return started
    }
    #expect(detects(1))
    #expect(!detects(0))
  }

  @Test func motionOutsideTheZoneDoesNotCount() {
    // The zone is the left half; a square moving on the right isn't motion, on the left it is, with its box
    func run(x: Int) -> (started: Bool, box: MotionDetector.Zone?) {
      var detector = MotionDetector(sensitivity: 0.5, zone: MotionDetector.Zone(x: 0, y: 0, width: 0.5, height: 1))
      _ = detector.process(luma: grid(), columns: 64, time: 0)
      var started = false
      var box: MotionDetector.Zone?
      for step in 0..<6 {
        if detector.process(luma: grid(square: 6, x: x + step, y: 12), columns: 64, time: 0.2 * Double(step + 1))?.isActive == true { started = true }
        box = detector.box ?? box
      }
      return (started, box)
    }
    #expect(!run(x: 45).started)
    let inside = run(x: 4)
    #expect(inside.started)
    #expect(inside.box.map { $0.x < 0.2 && $0.y > 0.2 && $0.y < 0.5 && $0.width < 0.3 } == true)
  }

  @Test func lightsTurningOnIsNotMotion() {
    var detector = MotionDetector(sensitivity: 1)
    _ = detector.process(luma: grid(base: 40), columns: 64, time: 0)
    for frame in 1..<10 {
      #expect(detector.process(luma: grid(base: 160), columns: 64, time: Double(frame) / 5) == nil)
    }
    #expect(!detector.isActive)
  }
}

@Suite struct EncodedVideoFrameTests {
  @Test func splitsAVCCAndWritesAnnexB() {
    let nal1 = Data([0x65, 1, 2, 3])
    let nal2 = Data([0x06, 9])
    var avcc = Data([0, 0, 0, 4]) + nal1
    avcc += Data([0, 0, 0, 2]) + nal2
    let frame = EncodedVideoFrame(
      data: avcc, isKeyframe: true, time: 0, duration: 0.1, parameterSets: [Data([0x67, 7]), Data([0x68, 8])],
      width: 16, height: 16)
    #expect(frame.nalUnits == [nal1, nal2])
    var expected = Data()
    for unit in [Data([0x67, 7]), Data([0x68, 8]), nal1, nal2] {
      expected.append(contentsOf: [0, 0, 0, 1])
      expected.append(unit)
    }
    #expect(frame.annexB == expected)
  }
}

#if canImport(AVFoundation) && canImport(CoreImage)
  import AVFoundation

  @Suite struct EncodingTests {
    /// Gray frames with a white bar that moves, 15 per second
    func frame(_ index: Int, width: Int = 320, height: Int = 240) -> CameraFrame {
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
      let pixelBuffer = buffer!
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      for plane in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        for row in 0..<rows {
          for column in 0..<stride {
            base[row * stride + column] = plane == 1 ? 128 : (column / 8 == index % (width / 8) ? 255 : 90)
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      return CameraFrame(pixelBuffer: pixelBuffer, time: 100 + Double(index) / 15)
    }

    @Test func lumaGridAndJPEG() {
      let frame = frame(3)
      let grid = frame.lumaGrid(columns: 40, rows: 30)
      #expect(grid.count == 1200)
      #expect(grid[3] == 255)
      #expect(grid[10] == 90)
      let jpeg = frame.jpeg(maxWidth: 160)
      #expect(jpeg?.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func encodesKeyframesWithParameterSetsIntoPlayableFragmentedMP4() async throws {
      let format = VideoFormat(width: 320, height: 240, fps: 15, bitrate: 300_000, keyframeInterval: 1)
      let encoder = try VideoEncoder(format: format)
      let writer = FragmentedMP4Writer(segmentDuration: 1)
      let frames = Collector<EncodedVideoFrame>()
      let fragments = Collector<MP4Fragment>()
      encoder.onFrame = { frame in
        frames.append(frame)
        writer.append(frame)
      }
      writer.onFragment = { fragments.append($0) }
      for index in 0..<60 {
        encoder.encode(frame(index))
        try await Task.sleep(for: .milliseconds(5))
      }
      encoder.invalidate()
      writer.finish()
      try await Task.sleep(for: .milliseconds(500))

      let encoded = frames.items
      #expect(encoded.count >= 55)
      #expect(encoded.first?.isKeyframe == true)
      #expect(encoded.first?.parameterSets.count == 2)
      #expect(encoded.first?.parameterSets.first?.first.map { $0 & 0x1F } == 7)
      // A keyframe every second at 15 fps
      #expect(encoded.filter(\.isKeyframe).count >= 3)

      let written = fragments.items
      #expect(written.first?.kind == .initialization)
      let media = written.filter { $0.kind == .media }
      #expect(media.count >= 2)
      #expect(media.allSatisfy { $0.duration > 0.5 })
      let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
      defer { try? FileManager.default.removeItem(at: file) }
      try written.reduce(Data()) { $0 + $1.data }.write(to: file)
      let asset = AVURLAsset(url: file)
      let duration = try await asset.load(.duration).seconds
      #expect(duration > 2)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      #expect(tracks.count == 1)
    }
  }

  @Suite struct HEVCTests {
    @Test func encodesHEVCWithThreeParameterSetsThatDescribeTheFormat() async throws {
      try #require(VideoEncoder.supports(.hevc))
      let format = VideoFormat(width: 320, height: 240, fps: 15, bitrate: 300_000, codec: .hevc)
      let encoder = try VideoEncoder(format: format)
      let frames = Collector<EncodedVideoFrame>()
      encoder.onFrame = { frames.append($0) }
      for index in 0..<20 {
        encoder.encode(EncodingTests().frame(index))
        try await Task.sleep(for: .milliseconds(5))
      }
      encoder.invalidate()
      try await Task.sleep(for: .milliseconds(300))
      let first = try #require(frames.items.first)
      #expect(first.codec == .hevc && first.isKeyframe)
      #expect(first.parameterSets.count == 3)
      let description = try #require(EncodedVideoFrame.formatDescription(parameterSets: first.parameterSets, codec: .hevc))
      #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
      #expect(first.sampleBuffer(description: description) != nil)
    }
  }

  final class Collector<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Item] = []
    func append(_ item: Item) { lock.withLock { list.append(item) } }
    var items: [Item] { lock.withLock { list } }
  }
#endif
