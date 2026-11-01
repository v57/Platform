import Foundation

/// Motion from frame differencing on a small grayscale grid (`CameraFrame.lumaGrid`): each cell is compared with a
/// slowly updated background, and the share of cells that changed is the frame's motion level. Motion starts when
/// that share passes the sensitivity's threshold on a few frames in a row, and ends after `cooldown` seconds without
/// it. A change of most of the picture at once (lights on or off, the camera adjusting its exposure) is taken as the
/// new background, not as motion.
public struct MotionDetector: Sendable {
  /// 0 (only large movement) … 1 (the smallest movement)
  public var sensitivity: Double {
    didSet { sensitivity = min(max(sensitivity, 0), 1) }
  }
  /// Seconds without motion before it ends
  public var cooldown: Double
  /// Consecutive frames over the threshold that start motion
  public var framesToStart: Int

  private var background: [Float] = []
  private var streak = 0
  private var lastMotion: Double?
  public private(set) var isActive = false
  public private(set) var level: Double = 0

  public init(sensitivity: Double = 0.5, cooldown: Double = 5, framesToStart: Int = 2) {
    self.sensitivity = min(max(sensitivity, 0), 1)
    self.cooldown = cooldown
    self.framesToStart = framesToStart
  }

  /// How far a cell's brightness (0…255) must move from the background to count as changed
  public var pixelThreshold: Float { Float(36 - 26 * sensitivity) }
  /// The share of cells that must change for motion: 6% at the lowest sensitivity, 0.3% at the highest
  public var areaThreshold: Double { 0.06 * pow(0.05, sensitivity) }
  /// A change this widespread is the light changing, not motion
  public static let globalChange = 0.65

  /// Takes the next frame's grid (row by row, any size that stays the same) at `time` seconds; returns the event
  /// when motion starts or ends with this frame.
  public mutating func process(luma: [UInt8], time: Double) -> MotionEvent? {
    guard background.count == luma.count, !luma.isEmpty else {
      background = luma.map(Float.init)
      level = 0
      return nil
    }
    let threshold = pixelThreshold
    var changed = 0
    for index in luma.indices where abs(Float(luma[index]) - background[index]) > threshold {
      changed += 1
    }
    let share = Double(changed) / Double(luma.count)
    // Follows slow changes (the sun moving); a global change replaces the background at once
    let rate: Float = share > Self.globalChange ? 1 : 0.05
    for index in luma.indices {
      background[index] += (Float(luma[index]) - background[index]) * rate
    }
    level = share > Self.globalChange ? 0 : share
    let moving = level >= areaThreshold
    streak = moving ? streak + 1 : 0
    if moving, streak >= framesToStart || isActive { lastMotion = time }
    if !isActive, streak >= framesToStart {
      isActive = true
      return MotionEvent(isActive: true, level: level)
    }
    if isActive, let lastMotion, time - lastMotion >= cooldown {
      isActive = false
      return MotionEvent(isActive: false, level: level)
    }
    return nil
  }

  /// Forgets the background, as after the camera moved
  public mutating func reset() {
    background = []
    streak = 0
    lastMotion = nil
    isActive = false
    level = 0
  }
}
