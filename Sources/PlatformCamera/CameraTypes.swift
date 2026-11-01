import Foundation

/// How to encode a video stream: picture size, frame rate and bit rate.
public struct VideoFormat: Sendable, Hashable, Codable {
  public var width: Int
  public var height: Int
  public var fps: Int
  /// Bits per second, the average the encoder aims for
  public var bitrate: Int
  /// Seconds between keyframes: how long a new viewer waits at most, and the shortest recording segment
  public var keyframeInterval: Double

  public init(width: Int, height: Int, fps: Int, bitrate: Int, keyframeInterval: Double = 1) {
    self.width = width
    self.height = height
    self.fps = fps
    self.bitrate = bitrate
    self.keyframeInterval = keyframeInterval
  }

  /// 1280×720 at 15 fps, 1.5 Mbit/s: a security camera's live view and recordings
  public static let hd = VideoFormat(width: 1280, height: 720, fps: 15, bitrate: 1_500_000)
  /// 640×360 at 15 fps, 400 kbit/s: thin links
  public static let low = VideoFormat(width: 640, height: 360, fps: 15, bitrate: 400_000)
}

/// One encoded H.264 access unit (a frame).
public struct EncodedVideoFrame: Sendable, Hashable {
  /// The frame's NAL units in AVCC form, each after a 4-byte big-endian length
  public var data: Data
  /// An IDR frame: decoding can start here
  public var isKeyframe: Bool
  /// Presentation time, seconds on the capture clock
  public var time: Double
  public var duration: Double
  /// SPS then PPS, without start codes or lengths; on every keyframe, empty on the others
  public var parameterSets: [Data]
  public var width: Int
  public var height: Int

  public init(
    data: Data, isKeyframe: Bool, time: Double, duration: Double, parameterSets: [Data], width: Int, height: Int
  ) {
    self.data = data
    self.isKeyframe = isKeyframe
    self.time = time
    self.duration = duration
    self.parameterSets = parameterSets
    self.width = width
    self.height = height
  }

  /// The NAL units without their lengths
  public var nalUnits: [Data] {
    var units = [Data]()
    var offset = data.startIndex
    while offset + 4 <= data.endIndex {
      let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      let start = offset + 4
      guard length > 0, start + length <= data.endIndex else { break }
      units.append(data[start..<start + length])
      offset = start + length
    }
    return units
  }

  /// Annex B (start codes) with the parameter sets before a keyframe: what RTP packetizers and files of raw H.264 take
  public var annexB: Data {
    let startCode = Data([0, 0, 0, 1])
    var result = Data()
    for unit in (isKeyframe ? parameterSets : []) + nalUnits {
      result.append(startCode)
      result.append(unit)
    }
    return result
  }
}

/// Motion starting or ending in front of the camera.
public struct MotionEvent: Sendable, Hashable, Codable {
  /// Motion is going on (from its start until it has been still for a while)
  public var isActive: Bool
  /// How much of the picture moved at the event, 0…1
  public var level: Double
  public var date: Date

  public init(isActive: Bool, level: Double, date: Date = Date()) {
    self.isActive = isActive
    self.level = level
    self.date = date
  }
}

/// A piece of a fragmented MP4 (ISO BMFF) recording.
public struct MP4Fragment: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    /// `ftyp` + `moov`: comes first, and again when the picture size changes
    case initialization
    /// `moof` + `mdat`: one segment, starting at a keyframe
    case media
  }
  public var kind: Kind
  public var data: Data
  /// Seconds on the capture clock; 0 for initialization
  public var time: Double
  public var duration: Double

  public init(kind: Kind, data: Data, time: Double, duration: Double) {
    self.kind = kind
    self.data = data
    self.time = time
    self.duration = duration
  }
}

/// A live H.264 stream from a `CameraFeed`, until `stop()` or until whoever iterates `frames` stops.
public final class CameraVideoStream: Sendable {
  public let format: VideoFormat
  public let frames: AsyncStream<EncodedVideoFrame>
  private let control: @Sendable (Control) -> Void

  public enum Control: Sendable {
    case bitrate(Int)
    case keyframe
    case stop
  }

  public init(format: VideoFormat, frames: AsyncStream<EncodedVideoFrame>, control: @escaping @Sendable (Control) -> Void) {
    self.format = format
    self.frames = frames
    self.control = control
  }

  /// Changes the bit rate mid-stream (HomeKit's reconfigure)
  public func setBitrate(_ bitsPerSecond: Int) { control(.bitrate(bitsPerSecond)) }
  /// Asks for an IDR frame now (a decoder lost packets)
  public func requestKeyframe() { control(.keyframe) }
  public func stop() { control(.stop) }
}

/// What a running camera offers to something that serves it elsewhere, such as a HomeKit accessory server (HAPKit's
/// camera, motion sensor and Secure Video recording): live H.264 at a requested format, a JPEG snapshot, motion events
/// and fragmented MP4 with a prebuffer.
public protocol CameraFeed: AnyObject, Sendable {
  /// The formats `video(_:)` produces as asked; others are encoded as close as the camera can
  var supportedFormats: [VideoFormat] { get }
  /// H.264 at `format`; the first frame is a keyframe with its SPS and PPS
  func video(_ format: VideoFormat) -> CameraVideoStream
  /// The newest picture as JPEG, scaled to `maxWidth` at most
  func snapshot(maxWidth: Int) async throws -> Data
  /// Motion starting and ending, from now on
  func motionEvents() -> AsyncStream<MotionEvent>
  /// The recording as fragmented MP4: an initialization fragment, the media fragments of the last `prebuffer`
  /// seconds that the camera keeps, then new ones as they are written, until the consumer stops iterating
  func recording(prebuffer: Double) -> AsyncStream<MP4Fragment>
}

public enum CameraError: Error, Equatable, LocalizedError, Sendable {
  /// This platform has no camera backend
  case unavailable
  /// The user didn't allow the camera
  case notAuthorized
  /// No camera is connected
  case noDevice
  /// The camera or encoder failed with a system status
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Cameras aren’t supported on this platform yet."
    case .notAuthorized: "Camera access is off. Allow it in Settings → Privacy & Security → Camera."
    case .noDevice: "This device has no camera."
    case .failed(let reason): reason
    }
  }
}
