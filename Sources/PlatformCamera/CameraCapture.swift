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

  /// Captures pictures from one of this device's cameras (AVCaptureSession; Linux has no backend yet).
  public final class CameraCapture: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
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

    /// The cameras, the default one first
    public static func devices() -> [CameraDevice] {
      #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
      #else
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .external]
      #endif
      let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
      let preferred = defaultDevice()?.uniqueID
      return found.sorted { a, b in a.uniqueID == preferred && b.uniqueID != preferred }.map(Self.device)
    }

    private static func device(_ device: AVCaptureDevice) -> CameraDevice {
      let position: CameraDevice.Position =
        switch device.position {
        case .front: .front
        case .back: .back
        default: .external
        }
      return CameraDevice(id: device.uniqueID, name: device.localizedName, position: position)
    }

    /// A security camera looks away from the screen: the back camera where there is one
    private static func defaultDevice() -> AVCaptureDevice? {
      AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        ?? AVCaptureDevice.default(for: .video)
    }

    /// Called on the capture queue for every picture
    public var onFrame: (@Sendable (CameraFrame) -> Void)?
    /// Called on the capture queue when capture stops by itself (the camera disconnected, another app took it)
    public var onInterruption: (@Sendable (String) -> Void)?
    public private(set) var device: CameraDevice?

    private let deviceID: String?
    private let width: Int
    private let height: Int
    private let fps: Int
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.v57.PlatformCamera.capture", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    /// `device`: a `CameraDevice.id`, or nil for the default camera. Captures the size closest to `width` × `height`
    /// the camera offers, at `fps` at most.
    public init(device: String? = nil, width: Int = 1280, height: Int = 720, fps: Int = 15) {
      deviceID = device
      self.width = width
      self.height = height
      self.fps = fps
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func start() throws {
      guard Self.access == .authorized else { throw CameraError.notAuthorized }
      guard let camera = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? Self.defaultDevice() else {
        throw CameraError.noDevice
      }
      device = Self.device(camera)
      session.beginConfiguration()
      defer { session.commitConfiguration() }
      session.inputs.forEach(session.removeInput)
      session.outputs.forEach(session.removeOutput)
      let input: AVCaptureDeviceInput
      do {
        input = try AVCaptureDeviceInput(device: camera)
      } catch {
        throw CameraError.failed(error.localizedDescription)
      }
      guard session.canAddInput(input) else { throw CameraError.failed("The camera is in use.") }
      session.addInput(input)
      let preset: AVCaptureSession.Preset = width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .vga640x480
      session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      let formats = output.availableVideoPixelFormatTypes
      let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        .first(where: formats.contains) ?? kCVPixelFormatType_32BGRA
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
      output.setSampleBufferDelegate(self, queue: queue)
      guard session.canAddOutput(output) else { throw CameraError.failed("The camera can’t deliver pictures.") }
      session.addOutput(output)
      observe()
      // After the configuration is committed: the preset resets the frame rate
      nonisolated(unsafe) let device = camera
      queue.async { [session, self] in
        self.limitFrameRate(device)
        session.startRunning()
      }
    }

    public func stop() {
      queue.async { [session] in session.stopRunning() }
    }

    /// Lowers the frame rate to `fps` where the camera's format allows it
    private func limitFrameRate(_ camera: AVCaptureDevice) {
      guard (try? camera.lockForConfiguration()) != nil else { return }
      defer { camera.unlockForConfiguration() }
      let ranges = camera.activeFormat.videoSupportedFrameRateRanges
      guard ranges.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) else { return }
      let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
      camera.activeVideoMinFrameDuration = duration
      camera.activeVideoMaxFrameDuration = duration
    }

    private func observe() {
      guard observers.isEmpty else { return }
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
          let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
          self?.onInterruption?(error?.localizedDescription ?? "The camera stopped.")
        })
      #if os(iOS)
        observers.append(
          center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.onInterruption?("Another app is using the camera, or Hub went to the background.")
          })
        observers.append(
          center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.onInterruption?("")
          })
      #endif
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      onFrame?(CameraFrame(pixelBuffer: pixelBuffer, time: time))
    }
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

  /// Captures pictures from a camera: no backend on this platform yet, so `start()` throws `CameraError.unavailable`.
  public final class CameraCapture: @unchecked Sendable {
    public static var isAvailable: Bool { false }
    public static var access: CameraAccess { .denied }
    public static func requestAccess() async -> Bool { false }
    public static func devices() -> [CameraDevice] { [] }
    public var onFrame: (@Sendable (CameraFrame) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public private(set) var device: CameraDevice?
    public init(device: String? = nil, width: Int = 1280, height: Int = 720, fps: Int = 15) {}
    public func start() throws { throw CameraError.unavailable }
    public func stop() {}
  }
#endif
