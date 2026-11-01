import Foundation

/// A camera this device can capture from.
public struct CameraDevice: Sendable, Hashable, Identifiable, Codable {
  public enum Position: String, Sendable, Codable {
    case front, back, external
  }
  public var id: String
  public var name: String
  public var position: Position

  public init(id: String, name: String, position: Position) {
    self.id = id
    self.name = name
    self.position = position
  }
}

/// Whether this app may use the camera.
public enum CameraAccess: Sendable {
  case notDetermined, authorized, denied
}

#if canImport(AVFoundation) && canImport(CoreImage)
  @preconcurrency import AVFoundation
  import CoreImage
  import ImageIO
  import UniformTypeIdentifiers

  /// One captured picture: a 4:2:0 pixel buffer and its time on the capture clock.
  public struct CameraFrame: @unchecked Sendable {
    public let time: Double
    let pixelBuffer: CVPixelBuffer

    init(pixelBuffer: CVPixelBuffer, time: Double) {
      self.pixelBuffer = pixelBuffer
      self.time = time
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }

    /// The picture's brightness as `columns` × `rows` cells, row by row, each the mean of a few samples of its area:
    /// what `MotionDetector` compares.
    public func lumaGrid(columns: Int, rows: Int) -> [UInt8] {
      CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
      let planar = CVPixelBufferIsPlanar(pixelBuffer)
      guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
      else { return [] }
      let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
      let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
      let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
      // Packed BGRA (a camera that won't give 4:2:0): its green byte stands in for brightness
      let step = planar ? 1 : 4
      let offset = planar ? 0 : 1
      let bytes = base.assumingMemoryBound(to: UInt8.self)
      let samples = 4
      var grid = [UInt8](repeating: 0, count: columns * rows)
      for row in 0..<rows {
        for column in 0..<columns {
          var sum = 0
          for sy in 0..<samples {
            let y = min(height - 1, (row * samples + sy) * height / (rows * samples) + height / (rows * samples * 2))
            for sx in 0..<samples {
              let x = min(width - 1, (column * samples + sx) * width / (columns * samples) + width / (columns * samples * 2))
              sum += Int(bytes[y * stride + x * step + offset])
            }
          }
          grid[row * columns + column] = UInt8(sum / (samples * samples))
        }
      }
      return grid
    }

    /// The picture as JPEG, scaled down to `maxWidth` at most
    public func jpeg(maxWidth: Int = 1280, quality: Double = 0.7) -> Data? {
      var image = CIImage(cvPixelBuffer: pixelBuffer)
      let scale = min(1, Double(maxWidth) / Double(width))
      if scale < 1 {
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      }
      guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
      }
      CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return data as Data
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
  }

  /// This device's cameras and camera access (AVFoundation); `CameraRig` captures from them.
  public enum CameraCapture {
    public static var isAvailable: Bool { true }

    public static var access: CameraAccess {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: .authorized
      case .notDetermined: .notDetermined
      default: .denied
      }
    }

    /// Asks the user once; afterwards answers what they chose
    public static func requestAccess() async -> Bool {
      await AVCaptureDevice.requestAccess(for: .video)
    }

    static var deviceTypes: [AVCaptureDevice.DeviceType] {
      #if os(macOS)
        [.builtInWideAngleCamera, .external, .continuityCamera]
      #else
        [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .external]
      #endif
    }

    static var discovery: AVCaptureDevice.DiscoverySession {
      AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
    }

    /// The cameras, the default one first
    public static func devices() -> [CameraDevice] {
      let preferred = defaultDevice()?.uniqueID
      return discovery.devices.sorted { a, b in a.uniqueID == preferred && b.uniqueID != preferred }.map(device)
    }

    static func device(_ device: AVCaptureDevice) -> CameraDevice {
      let position: CameraDevice.Position =
        switch device.position {
        case .front: .front
        case .back: .back
        default: .external
        }
      return CameraDevice(id: device.uniqueID, name: device.localizedName, position: position)
    }

    /// A security camera looks away from the screen: the back camera where there is one
    static func defaultDevice() -> AVCaptureDevice? {
      AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        ?? AVCaptureDevice.default(for: .video)
    }

    /// The default camera's id
    public static var defaultDeviceID: String? { defaultDevice()?.uniqueID }
  }
#else
  /// One captured picture (no camera backend on this platform yet).
  public struct CameraFrame: Sendable {
    public let time: Double
    public var width: Int { 0 }
    public var height: Int { 0 }
    public func lumaGrid(columns: Int, rows: Int) -> [UInt8] { [] }
    public func jpeg(maxWidth: Int = 1280, quality: Double = 0.7) -> Data? { nil }
  }

  /// This device's cameras: none on this platform yet.
  public enum CameraCapture {
    public static var isAvailable: Bool { false }
    public static var access: CameraAccess { .denied }
    public static func requestAccess() async -> Bool { false }
    public static func devices() -> [CameraDevice] { [] }
    public static var defaultDeviceID: String? { nil }
  }
#endif
