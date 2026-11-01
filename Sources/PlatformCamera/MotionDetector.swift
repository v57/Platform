import Foundation

/// Motion from frame differencing on a small grayscale grid (`CameraFrame.lumaGrid`): each cell is compared with a
/// slowly updated background, and the share of cells that changed is the frame's motion level. Motion starts when
/// that share passes the sensitivity's threshold on a few frames in a row, and ends after `cooldown` seconds without
/// it. A change of most of the picture at once (lights on or off, the camera adjusting its exposure) is taken as the
/// new background, not as motion. With a `zone`, only cells inside it count, and the level is the share of the zone.
public struct MotionDetector: Sendable {
  /// Where motion counts, in parts of the picture (0…1, origin top left)
  public struct Zone: Sendable, Hashable, Codable {
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

    public static let all = Zone(x: 0, y: 0, width: 1, height: 1)

    func contains(column: Int, of columns: Int, row: Int, of rows: Int) -> Bool {
      let cx = (Double(column) + 0.5) / Double(columns)
      let cy = (Double(row) + 0.5) / Double(rows)
      return cx >= x && cx <= x + width && cy >= y && cy <= y + height
    }
  }

  /// 0 (only large movement) … 1 (the smallest movement)
  public var sensitivity: Double {
    didSet { sensitivity = min(max(sensitivity, 0), 1) }
  }
  /// Seconds without motion before it ends
  public var cooldown: Double
  /// Consecutive frames over the threshold that start motion
  public var framesToStart: Int
  /// Where motion counts; nil for the whole picture
  public var zone: Zone? {
    didSet { if zone != oldValue { mask = [] } }
  }

  private var background: [Float] = []
  private var streak = 0
  private var lastMotion: Double?
  private var mask: [Bool] = []
  public private(set) var isActive = false
  public private(set) var level: Double = 0
  /// The changed cells' bounding box on the last frame, in parts of the picture; nil when nothing changed
  public private(set) var box: Zone?

  public init(sensitivity: Double = 0.5, cooldown: Double = 5, framesToStart: Int = 2, zone: Zone? = nil) {
    self.sensitivity = min(max(sensitivity, 0), 1)
    self.cooldown = cooldown
    self.framesToStart = framesToStart
    self.zone = zone
  }

  /// How far a cell's brightness (0…255) must move from the background to count as changed
  public var pixelThreshold: Float { Float(36 - 26 * sensitivity) }
  /// The share of cells that must change for motion: 6% at the lowest sensitivity, 0.3% at the highest
  public var areaThreshold: Double { 0.06 * pow(0.05, sensitivity) }
  /// A change this widespread is the light changing, not motion
  public static let globalChange = 0.65

  /// Takes the next frame's grid (`columns` wide, row by row, a size that stays the same) at `time` seconds; returns
  /// the event when motion starts or ends with this frame.
  public mutating func process(luma: [UInt8], columns: Int, time: Double) -> MotionEvent? {
    guard background.count == luma.count, !luma.isEmpty, columns > 0 else {
      background = luma.map(Float.init)
      level = 0
      box = nil
      return nil
    }
    let rows = luma.count / columns
    if mask.count != luma.count {
      let zone = zone ?? .all
      mask = luma.indices.map { zone.contains(column: $0 % columns, of: columns, row: $0 / columns, of: rows) }
    }
    let threshold = pixelThreshold
    var changed = 0
    var counted = 0
    var (left, top, right, bottom) = (columns, rows, -1, -1)
    for index in luma.indices where mask[index] {
      counted += 1
      guard abs(Float(luma[index]) - background[index]) > threshold else { continue }
      changed += 1
      let (column, row) = (index % columns, index / columns)
      (left, top, right, bottom) = (min(left, column), min(top, row), max(right, column), max(bottom, row))
    }
    let share = counted == 0 ? 0 : Double(changed) / Double(counted)
    box =
      changed == 0 || share > Self.globalChange
      ? nil
      : Zone(
        x: Double(left) / Double(columns), y: Double(top) / Double(rows), width: Double(right - left + 1) / Double(columns),
        height: Double(bottom - top + 1) / Double(rows))
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
    box = nil
    streak = 0
    lastMotion = nil
    isActive = false
    level = 0
  }
}
