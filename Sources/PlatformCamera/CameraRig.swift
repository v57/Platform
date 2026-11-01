import Foundation

/// How a camera adjusts its picture. A security camera on a stand gains from adjusting less: nothing hunts when the
/// light changes, and the device stays cooler.
public struct CameraPicture: Sendable, Hashable, Codable {
  public enum Adjustment: String, Sendable, Hashable, Codable, CaseIterable {
    /// All the time
    case auto
    /// Once every `CameraPicture.slowInterval` seconds, locked in between
    case slow
    /// Not at all: kept where it is (or where Lock Now put it)
    case locked
  }

  /// Video stabilization (iPhone and iPad cameras that have it)
  public var stabilization: Bool
  public var focus: Adjustment
  public var exposure: Adjustment
  public var whiteBalance: Adjustment

  public init(stabilization: Bool = false, focus: Adjustment = .auto, exposure: Adjustment = .auto, whiteBalance: Adjustment = .auto) {
    self.stabilization = stabilization
    self.focus = focus
    self.exposure = exposure
    self.whiteBalance = whiteBalance
  }

  public static let slowInterval: Double = 10
}

/// What one camera can do, for a settings page.
public struct CameraCapabilities: Sendable, Hashable {
  public struct Size: Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// The highest frame rate at this size
    public var maxFPS: Int
  }

  /// The 16:9 sizes (`CameraCapabilities.standardSizes`) it captures, smallest first
  public var sizes: [Size]
  public var stabilization: Bool
  /// Whether focus, exposure and white balance can be locked (built-in Mac cameras adjust by themselves)
  public var focus: Bool
  public var exposure: Bool
  public var whiteBalance: Bool

  public init(sizes: [Size] = [], stabilization: Bool = false, focus: Bool = false, exposure: Bool = false, whiteBalance: Bool = false) {
    self.sizes = sizes
    self.stabilization = stabilization
    self.focus = focus
    self.exposure = exposure
    self.whiteBalance = whiteBalance
  }

  public func maxFPS(height: Int) -> Int? { sizes.first { $0.height == height }?.maxFPS }

  /// 360p … 2160p
  public static let standardSizes = [(640, 360), (854, 480), (1280, 720), (1920, 1080), (3840, 2160)]
}

/// What Lock Now froze the picture at.
public struct CameraLockedValues: Sendable, Hashable, Codable {
  public var iso: Double?
  /// Seconds
  public var shutter: Double?
  /// Kelvin
  public var temperature: Double?
  /// 0 (nearest) … 1 (farthest)
  public var lensPosition: Double?
  public var date: Date

  public init(iso: Double? = nil, shutter: Double? = nil, temperature: Double? = nil, lensPosition: Double? = nil, date: Date = Date()) {
    self.iso = iso
    self.shutter = shutter
    self.temperature = temperature
    self.lensPosition = lensPosition
    self.date = date
  }
}

/// The system's own measure of how hard the cameras work: iOS's costs of a multi-camera session (1.0 is the limit)
/// and the cameras' system pressure; a Mac reports only its thermal state.
public struct CameraBudget: Sendable, Hashable {
  public enum Pressure: Int, Sendable, Hashable, Comparable, CaseIterable {
    case nominal, fair, serious, critical, shutdown

    public var title: String {
      switch self {
      case .nominal: "Nominal"
      case .fair: "Fair"
      case .serious: "Serious"
      case .critical: "Critical"
      case .shutdown: "Shutdown"
      }
    }

    public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
  }

  /// How much of the camera hardware the cameras together use (multi-camera sessions only)
  public var hardwareCost: Double?
  /// Whether they can run sustainably: above 1.0 iOS slows or stops them before long (multi-camera sessions only)
  public var systemPressureCost: Double?
  public var pressure: Pressure
  /// What raises the pressure: "temperature", "peak power", "depth module"
  public var factors: [String]

  public init(hardwareCost: Double? = nil, systemPressureCost: Double? = nil, pressure: Pressure = .nominal, factors: [String] = []) {
    self.hardwareCost = hardwareCost
    self.systemPressureCost = systemPressureCost
    self.pressure = pressure
    self.factors = factors
  }
}

/// One camera a `CameraRig` runs.
public struct CameraConfiguration: Sendable, Hashable {
  /// A `CameraDevice.id`
  public var device: String
  public var width: Int
  public var height: Int
  public var fps: Int
  public var picture: CameraPicture

  public init(device: String, width: Int, height: Int, fps: Int, picture: CameraPicture = CameraPicture()) {
    self.device = device
    self.width = width
    self.height = height
    self.fps = fps
    self.picture = picture
  }
}

#if canImport(AVFoundation) && canImport(CoreImage)
  @preconcurrency import AVFoundation

  /// Captures from several of this device's cameras at once: one AVCaptureSession per camera on a Mac; on iPhone and
  /// iPad one session, an AVCaptureMultiCamSession once more than one camera runs (which reports what they cost
  /// together). Each camera gets the device format closest above its size that reaches its frame rate, and its
  /// picture adjustments.
  public final class CameraRig: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// How many cameras can capture at once
    public static var maximumCameras: Int {
      #if os(iOS)
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return 1 }
        return max(1, CameraCapture.discovery.supportedMultiCamDeviceSets.map(\.count).max() ?? 1)
      #else
        return max(1, CameraCapture.devices().count)
      #endif
    }

    /// Whether these cameras can capture together
    public static func canRun(together devices: [String]) -> Bool {
      guard devices.count > 1 else { return true }
      #if os(iOS)
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }
        let wanted = Set(devices)
        return CameraCapture.discovery.supportedMultiCamDeviceSets.contains { set in wanted.isSubset(of: Set(set.map(\.uniqueID))) }
      #else
        return true
      #endif
    }

    /// What `device` can do while `together` cameras run (iPhone and iPad offer fewer formats to several at once)
    public static func capabilities(of device: String, together: Int = 1) -> CameraCapabilities {
      guard let camera = AVCaptureDevice(uniqueID: device) else { return CameraCapabilities() }
      let formats = candidates(camera, multiCam: together > 1)
      let sizes = CameraCapabilities.standardSizes.compactMap { width, height -> CameraCapabilities.Size? in
        let fps = formats.filter { $0.dimensions.width >= width && $0.dimensions.height >= height }.map(\.maxFPS).max()
        return fps.map { CameraCapabilities.Size(width: width, height: height, maxFPS: min($0, 60)) }
      }
      #if os(iOS)
        let stabilization = formats.contains { $0.format.isVideoStabilizationModeSupported(.standard) }
      #else
        let stabilization = false
      #endif
      return CameraCapabilities(
        sizes: sizes, stabilization: stabilization, focus: camera.isFocusModeSupported(.locked),
        exposure: camera.isExposureModeSupported(.locked), whiteBalance: camera.isWhiteBalanceModeSupported(.locked))
    }

    /// Called on the camera's queue for every picture, with its `CameraDevice.id`
    public var onFrame: (@Sendable (String, CameraFrame) -> Void)?
    /// Called when capture stops by itself (the camera disconnected, another app took it, the device is too hot),
    /// with an empty reason when it comes back
    public var onInterruption: (@Sendable (String) -> Void)?
    /// Called when the system pressure changes
    public var onBudget: (@Sendable (CameraBudget) -> Void)?

    private struct Running {
      var configuration: CameraConfiguration
      let device: AVCaptureDevice
      let input: AVCaptureDeviceInput
      let output: AVCaptureVideoDataOutput
      let queue: DispatchQueue
      #if os(macOS)
        let session: AVCaptureSession
      #endif
    }

    /// Everything below is touched on `sessionQueue` only
    private let sessionQueue = DispatchQueue(label: "dev.v57.PlatformCamera.rig", qos: .userInitiated)
    private var running: [String: Running] = [:]
    #if os(iOS)
      private var session: AVCaptureSession?
    #endif
    /// Notification observers by session (one session on iPhone and iPad)
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var thermalObserver: NSObjectProtocol?
    private var pressureObservations: [NSKeyValueObservation] = []
    private var slowTimer: DispatchSourceTimer?
    private let outputsLock = NSLock()
    private var outputDevices: [ObjectIdentifier: String] = [:]

    public override init() {
      super.init()
    }

    deinit {
      observers.values.joined().forEach(NotificationCenter.default.removeObserver)
      thermalObserver.map(NotificationCenter.default.removeObserver)
    }

    private func stopObserving(_ session: AVCaptureSession) {
      observers.removeValue(forKey: ObjectIdentifier(session))?.forEach(NotificationCenter.default.removeObserver)
    }

    /// Runs exactly these cameras, with these sizes, frame rates and pictures; cameras left out stop. Blocks until
    /// the sessions are configured.
    public func run(_ cameras: [CameraConfiguration]) throws {
      guard CameraCapture.access == .authorized else { throw CameraError.notAuthorized }
      guard Self.canRun(together: cameras.map(\.device)) else {
        throw CameraError.failed("These cameras can’t run together on this device.")
      }
      try sessionQueue.sync { try configure(cameras) }
    }

    public func stop() {
      try? run([])
    }

    /// What the cameras cost now
    public var budget: CameraBudget {
      sessionQueue.sync { currentBudget() }
    }

    /// What the running cameras would cost with these sizes and frame rates (the same cameras, tried inside a
    /// configuration that is undone); nil where the system has no cost numbers (one camera, a Mac)
    public func estimate(_ cameras: [CameraConfiguration]) -> CameraBudget? {
      #if os(iOS)
        sessionQueue.sync {
          guard let session = session as? AVCaptureMultiCamSession, Set(cameras.map(\.device)) == Set(running.keys) else { return nil }
          session.beginConfiguration()
          var restore: [(AVCaptureDevice, AVCaptureDevice.Format, CMTime)] = []
          for camera in cameras {
            guard let current = running[camera.device], (try? current.device.lockForConfiguration()) != nil else { continue }
            restore.append((current.device, current.device.activeFormat, current.input.videoMinFrameDurationOverride))
            if let format = Self.format(current.device, width: camera.width, height: camera.height, fps: camera.fps, multiCam: true) {
              current.device.activeFormat = format
            }
            current.input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: CMTimeScale(camera.fps))
            current.device.unlockForConfiguration()
          }
          let budget = CameraBudget(
            hardwareCost: Double(session.hardwareCost), systemPressureCost: Double(session.systemPressureCost),
            pressure: currentBudget().pressure, factors: currentBudget().factors)
          for (device, format, duration) in restore where (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            running[device.uniqueID]?.input.videoMinFrameDurationOverride = duration
            device.unlockForConfiguration()
          }
          session.commitConfiguration()
          return budget
        }
      #else
        nil
      #endif
    }

    /// Locks focus, exposure and white balance where they are now, and says where that is
    public func lockNow(device: String) -> CameraLockedValues? {
      sessionQueue.sync {
        guard let camera = running[device]?.device, (try? camera.lockForConfiguration()) != nil else { return nil }
        defer { camera.unlockForConfiguration() }
        if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
        if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
        if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
        #if os(iOS)
          let gains = camera.deviceWhiteBalanceGains
          let temperature = camera.temperatureAndTintValues(for: gains).temperature
          return CameraLockedValues(
            iso: Double(camera.iso), shutter: camera.exposureDuration.seconds, temperature: Double(temperature),
            lensPosition: Double(camera.lensPosition))
        #else
          return CameraLockedValues()
        #endif
      }
    }

    // MARK: Configuration

    private func configure(_ cameras: [CameraConfiguration]) throws {
      let wanted = Dictionary(cameras.map { ($0.device, $0) }, uniquingKeysWith: { a, _ in a })
      #if os(iOS)
        try configureShared(wanted)
      #else
        try configureSeparate(wanted)
      #endif
      observePressure()
      updateSlowTimer()
    }

    #if os(iOS)
      /// One session for all cameras: a multi-camera one when there's more than one
      private func configureShared(_ wanted: [String: CameraConfiguration]) throws {
        let multiCam = wanted.count > 1
        if let session, (session is AVCaptureMultiCamSession) != multiCam || wanted.isEmpty {
          session.stopRunning()
          tearDown(session)
          self.session = nil
        }
        guard !wanted.isEmpty else { return }
        let session = self.session ?? (multiCam ? AVCaptureMultiCamSession() : AVCaptureSession())
        let isNew = self.session == nil
        self.session = session
        session.beginConfiguration()
        var failure: Error?
        // Cameras that stay keep their input; the others go or come
        for (id, camera) in running where wanted[id] == nil {
          session.removeOutput(camera.output)
          session.removeInput(camera.input)
          forget(camera.output)
          running[id] = nil
        }
        for (id, configuration) in wanted {
          do {
            if var camera = running[id] {
              camera.configuration = configuration
              running[id] = camera
              try apply(configuration, to: camera, multiCam: multiCam)
            } else {
              let camera = try add(configuration, to: session, multiCam: multiCam)
              running[id] = camera
              try apply(configuration, to: camera, multiCam: multiCam)
            }
          } catch {
            failure = error
          }
        }
        if !multiCam { session.sessionPreset = .inputPriority }
        session.commitConfiguration()
        if isNew { observe(session) }
        if let failure { throw failure }
        if !session.isRunning { session.startRunning() }
      }

      private func add(_ configuration: CameraConfiguration, to session: AVCaptureSession, multiCam: Bool) throws -> Running {
        guard let device = AVCaptureDevice(uniqueID: configuration.device) else { throw CameraError.noDevice }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.failed(error.localizedDescription) }
        let output = makeOutput(for: configuration.device)
        if let session = session as? AVCaptureMultiCamSession {
          guard session.canAddInput(input) else { throw CameraError.failed("\(device.localizedName) can’t run with the others.") }
          session.addInputWithNoConnections(input)
          guard session.canAddOutput(output) else { throw CameraError.failed("\(device.localizedName) can’t deliver pictures.") }
          session.addOutputWithNoConnections(output)
          guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first
          else { throw CameraError.failed("\(device.localizedName) has no video.") }
          let connection = AVCaptureConnection(inputPorts: [port], output: output)
          guard session.canAddConnection(connection) else { throw CameraError.failed("\(device.localizedName) can’t run with the others.") }
          session.addConnection(connection)
        } else {
          guard session.canAddInput(input) else { throw CameraError.failed("The camera is in use.") }
          session.addInput(input)
          guard session.canAddOutput(output) else { throw CameraError.failed("The camera can’t deliver pictures.") }
          session.addOutput(output)
        }
        return Running(configuration: configuration, device: device, input: input, output: output, queue: queue(for: configuration.device))
      }

      private func tearDown(_ session: AVCaptureSession) {
        session.beginConfiguration()
        session.connections.forEach(session.removeConnection)
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        running.values.forEach { forget($0.output) }
        running = [:]
        stopObserving(session)
      }
    #else
      /// A session of its own for each camera
      private func configureSeparate(_ wanted: [String: CameraConfiguration]) throws {
        for (id, camera) in running where wanted[id] == nil {
          camera.session.stopRunning()
          stopObserving(camera.session)
          forget(camera.output)
          running[id] = nil
        }
        var failure: Error?
        for (id, configuration) in wanted {
          do {
            if var camera = running[id] {
              camera.configuration = configuration
              running[id] = camera
              camera.session.beginConfiguration()
              try apply(configuration, to: camera, multiCam: false)
              camera.session.commitConfiguration()
            } else {
              guard let device = AVCaptureDevice(uniqueID: configuration.device) else { throw CameraError.noDevice }
              let session = AVCaptureSession()
              let input: AVCaptureDeviceInput
              do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.failed(error.localizedDescription) }
              session.beginConfiguration()
              guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraError.failed("\(device.localizedName) is in use.")
              }
              session.addInput(input)
              let output = makeOutput(for: id)
              guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraError.failed("\(device.localizedName) can’t deliver pictures.")
              }
              session.addOutput(output)
              let camera = Running(
                configuration: configuration, device: device, input: input, output: output, queue: queue(for: id), session: session)
              try apply(configuration, to: camera, multiCam: false)
              session.commitConfiguration()
              observe(session)
              running[id] = camera
              session.startRunning()
            }
          } catch {
            failure = error
          }
        }
        if let failure { throw failure }
      }
    #endif

    private func makeOutput(for device: String) -> AVCaptureVideoDataOutput {
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      let formats = output.availableVideoPixelFormatTypes
      let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        .first(where: formats.contains) ?? kCVPixelFormatType_32BGRA
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
      output.setSampleBufferDelegate(self, queue: queue(for: device))
      outputsLock.withLock { outputDevices[ObjectIdentifier(output)] = device }
      return output
    }

    private var queues: [String: DispatchQueue] = [:]
    private func queue(for device: String) -> DispatchQueue {
      if let queue = queues[device] { return queue }
      let queue = DispatchQueue(label: "dev.v57.PlatformCamera.capture.\(queues.count)", qos: .userInitiated)
      queues[device] = queue
      return queue
    }

    private func forget(_ output: AVCaptureVideoDataOutput) {
      output.setSampleBufferDelegate(nil, queue: nil)
      _ = outputsLock.withLock { outputDevices.removeValue(forKey: ObjectIdentifier(output)) }
    }

    /// The camera's format, frame rate and picture, inside the session's configuration
    private func apply(_ configuration: CameraConfiguration, to camera: Running, multiCam: Bool) throws {
      let device = camera.device
      guard (try? device.lockForConfiguration()) != nil else { throw CameraError.failed("\(device.localizedName) is busy.") }
      defer { device.unlockForConfiguration() }
      if let format = Self.format(device, width: configuration.width, height: configuration.height, fps: configuration.fps, multiCam: multiCam),
        format != device.activeFormat
      {
        device.activeFormat = format
      }
      let fps = Double(configuration.fps)
      if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        #if os(iOS)
          // Pays the hardware cost of this frame rate, not of the format's highest
          if multiCam { camera.input.videoMinFrameDurationOverride = duration }
        #endif
      }
      let picture = configuration.picture
      Self.set(focus: picture.focus, on: device)
      Self.set(exposure: picture.exposure, on: device)
      Self.set(whiteBalance: picture.whiteBalance, on: device)
      #if os(iOS)
        if let connection = camera.output.connection(with: .video), connection.isVideoStabilizationSupported {
          connection.preferredVideoStabilizationMode = picture.stabilization ? .standard : .off
        }
      #endif
    }

    private static func set(focus: CameraPicture.Adjustment, on device: AVCaptureDevice) {
      let mode: AVCaptureDevice.FocusMode = focus == .locked ? .locked : focus == .slow ? .autoFocus : .continuousAutoFocus
      if device.isFocusModeSupported(mode) {
        device.focusMode = mode
      } else if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
    }

    private static func set(exposure: CameraPicture.Adjustment, on device: AVCaptureDevice) {
      let mode: AVCaptureDevice.ExposureMode = exposure == .locked ? .locked : exposure == .slow ? .autoExpose : .continuousAutoExposure
      if device.isExposureModeSupported(mode) {
        device.exposureMode = mode
      } else if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
    }

    private static func set(whiteBalance: CameraPicture.Adjustment, on device: AVCaptureDevice) {
      let mode: AVCaptureDevice.WhiteBalanceMode =
        whiteBalance == .locked ? .locked : whiteBalance == .slow ? .autoWhiteBalance : .continuousAutoWhiteBalance
      if device.isWhiteBalanceModeSupported(mode) {
        device.whiteBalanceMode = mode
      } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        device.whiteBalanceMode = .continuousAutoWhiteBalance
      }
    }

    /// Slow adjustments: the one-shot modes lock again by themselves after adjusting, so they're started again every
    /// `slowInterval` seconds
    private func updateSlowTimer() {
      let slow = running.values.contains { camera in
        let picture = camera.configuration.picture
        return [picture.focus, picture.exposure, picture.whiteBalance].contains(.slow)
      }
      guard slow else {
        slowTimer?.cancel()
        slowTimer = nil
        return
      }
      guard slowTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
      timer.schedule(deadline: .now() + CameraPicture.slowInterval, repeating: CameraPicture.slowInterval)
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        for camera in self.running.values {
          let picture = camera.configuration.picture
          guard [picture.focus, picture.exposure, picture.whiteBalance].contains(.slow),
            (try? camera.device.lockForConfiguration()) != nil
          else { continue }
          if picture.focus == .slow { Self.set(focus: .slow, on: camera.device) }
          if picture.exposure == .slow { Self.set(exposure: .slow, on: camera.device) }
          if picture.whiteBalance == .slow { Self.set(whiteBalance: .slow, on: camera.device) }
          camera.device.unlockForConfiguration()
        }
      }
      timer.resume()
      slowTimer = timer
    }

    // MARK: Formats

    private struct Candidate {
      let format: AVCaptureDevice.Format
      let dimensions: CMVideoDimensions
      let maxFPS: Int
    }

    private static func candidates(_ device: AVCaptureDevice, multiCam: Bool) -> [Candidate] {
      device.formats.compactMap { format in
        #if os(iOS)
          if multiCam, !format.isMultiCamSupported { return nil }
          let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
          // Not the 10-bit HDR or ProRes formats
          guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          else { return nil }
        #endif
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return Candidate(format: format, dimensions: CMVideoFormatDescriptionGetDimensions(format.formatDescription), maxFPS: Int(fps.rounded()))
      }
    }

    /// The smallest format at least this big that reaches `fps` (binned ones first, which cost less); else the
    /// biggest that reaches it; else the biggest
    static func format(_ device: AVCaptureDevice, width: Int, height: Int, fps: Int, multiCam: Bool) -> AVCaptureDevice.Format? {
      let all = candidates(device, multiCam: multiCam)
      let fast = all.filter { $0.maxFPS >= fps }
      func area(_ candidate: Candidate) -> Int { Int(candidate.dimensions.width) * Int(candidate.dimensions.height) }
      func binned(_ candidate: Candidate) -> Bool {
        #if os(iOS)
          candidate.format.isVideoBinned
        #else
          false
        #endif
      }
      let fitting = fast.filter { Int($0.dimensions.width) >= width && Int($0.dimensions.height) >= height }
      if let best = fitting.min(by: { (area($0), binned($0) ? 0 : 1) < (area($1), binned($1) ? 0 : 1) }) { return best.format }
      return (fast.max { area($0) < area($1) } ?? all.max { area($0) < area($1) })?.format
    }

    // MARK: Budget

    private func currentBudget() -> CameraBudget {
      var budget = CameraBudget()
      #if os(iOS)
        if let session = session as? AVCaptureMultiCamSession {
          budget.hardwareCost = Double(session.hardwareCost)
          budget.systemPressureCost = Double(session.systemPressureCost)
        }
        for camera in running.values {
          let state = camera.device.systemPressureState
          let pressure: CameraBudget.Pressure =
            switch state.level {
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            case .shutdown: .shutdown
            default: .nominal
            }
          budget.pressure = max(budget.pressure, pressure)
          if state.factors.contains(.systemTemperature) { budget.factors.append("temperature") }
          if state.factors.contains(.peakPower) { budget.factors.append("peak power") }
          if state.factors.contains(.depthModuleTemperature) { budget.factors.append("depth module") }
        }
        budget.factors = Array(Set(budget.factors)).sorted()
      #else
        budget.pressure =
          switch ProcessInfo.processInfo.thermalState {
          case .fair: .fair
          case .serious: .serious
          case .critical: .critical
          default: .nominal
          }
        if budget.pressure > .nominal { budget.factors = ["temperature"] }
      #endif
      return budget
    }

    private func observePressure() {
      pressureObservations = []
      #if os(iOS)
        for camera in running.values {
          pressureObservations.append(
            camera.device.observe(\.systemPressureState, options: [.new]) { [weak self] _, _ in
              guard let self else { return }
              self.sessionQueue.async { self.onBudget?(self.currentBudget()) }
            })
        }
      #else
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
          forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
          guard let self else { return }
          self.sessionQueue.async { self.onBudget?(self.currentBudget()) }
        }
      #endif
    }

    private func observe(_ session: AVCaptureSession) {
      let center = NotificationCenter.default
      var observers: [NSObjectProtocol] = []
      defer { self.observers[ObjectIdentifier(session), default: []] += observers }
      observers.append(
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
          let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
          self?.onInterruption?(error?.localizedDescription ?? "The camera stopped.")
        })
      #if os(iOS)
        observers.append(
          center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
            let text =
              switch reason {
              case .videoDeviceNotAvailableDueToSystemPressure: "The camera stopped because the device is too hot. It comes back when it cools down."
              case .videoDeviceInUseByAnotherClient: "Another app is using the camera. It comes back on its own."
              case .videoDeviceNotAvailableWithMultipleForegroundApps: "The camera pauses while Hub shares the screen with another app."
              default: "Hub went to the background, so iOS paused the camera. Open Hub to go on."
              }
            self?.onInterruption?(text)
          })
        observers.append(
          center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.onInterruption?("")
          })
      #endif
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
        let device = outputsLock.withLock({ outputDevices[ObjectIdentifier(output)] })
      else { return }
      let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      onFrame?(device, CameraFrame(pixelBuffer: pixelBuffer, time: time))
    }
  }
#else
  /// Captures from this device's cameras: no backend on this platform yet, so `run` throws `CameraError.unavailable`.
  public final class CameraRig: @unchecked Sendable {
    public static var maximumCameras: Int { 0 }
    public static func canRun(together devices: [String]) -> Bool { false }
    public static func capabilities(of device: String, together: Int = 1) -> CameraCapabilities { CameraCapabilities() }
    public var onFrame: (@Sendable (String, CameraFrame) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public var onBudget: (@Sendable (CameraBudget) -> Void)?
    public init() {}
    public func run(_ cameras: [CameraConfiguration]) throws { if !cameras.isEmpty { throw CameraError.unavailable } }
    public func stop() {}
    public var budget: CameraBudget { CameraBudget() }
    public func estimate(_ cameras: [CameraConfiguration]) -> CameraBudget? { nil }
    public func lockNow(device: String) -> CameraLockedValues? { nil }
  }
#endif
