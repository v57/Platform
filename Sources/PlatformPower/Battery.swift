import Foundation

#if os(macOS)
import IOKit.ps
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// The device's internal battery.
public struct Battery: Sendable, Hashable {
  /// Charge, 0...1
  public var level: Double
  /// On external power: charging, or full and plugged in
  public var isCharging: Bool

  public init(level: Double, isCharging: Bool) {
    self.level = level
    self.isCharging = isCharging
  }

  /// The internal battery now; `nil` on a device without one (a desktop, a simulator, a VM).
  /// macOS: IOKit's power sources. iOS: UIDevice. Linux: /sys/class/power_supply. Elsewhere `nil`.
  @MainActor public static var current: Battery? {
    #if os(macOS)
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Int,
        let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
      else { continue }
      let charging =
        description[kIOPSIsChargingKey] as? Bool
        ?? (description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
      return Battery(level: Double(current) / Double(max), isCharging: charging)
    }
    return nil
    #elseif os(iOS) || os(visionOS)
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    // -1 and .unknown on the simulator and on devices without a battery
    guard device.batteryLevel >= 0 else { return nil }
    return Battery(
      level: Double(device.batteryLevel), isCharging: device.batteryState == .charging || device.batteryState == .full)
    #elseif os(Linux) || os(Android)
    return LinuxPowerSupply.battery()
    #else
    return nil
    #endif
  }

  /// Calls `change` on the main actor whenever the battery changes, until the observation is released or cancelled.
  @MainActor public static func observe(_ change: @escaping @MainActor (Battery?) -> Void) -> BatteryObservation {
    BatteryObservation(change)
  }
}

/// A running battery observation; releasing it stops it.
@MainActor public final class BatteryObservation {
  private let change: @MainActor (Battery?) -> Void
  private var last: Battery??
  private var cleanup: Cleanup?

  init(_ change: @escaping @MainActor (Battery?) -> Void) {
    self.change = change
    last = .some(Battery.current)
    #if os(macOS)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let source = IOPSNotificationCreateRunLoopSource(
      { context in
        guard let context else { return }
        let observation = Unmanaged<BatteryObservation>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { observation.check() }
      }, context
    )?.takeRetainedValue()
    if let source {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
      cleanup = Cleanup { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
    #elseif os(iOS) || os(visionOS)
    UIDevice.current.isBatteryMonitoringEnabled = true
    let observers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map {
      NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.check() }
      }
    }
    cleanup = Cleanup { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    #else
    // sysfs has no change notification without udev: read it again every 30 s (a few small files).
    let timer = Timer(fire: Date(timeIntervalSinceNow: 30), interval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    cleanup = Cleanup { timer.invalidate() }
    #endif
  }

  private func check() {
    let battery = Battery.current
    guard last != .some(battery) else { return }
    last = .some(battery)
    change(battery)
  }

  /// Stops the observation (also when it's released).
  public func cancel() {
    cleanup?.run()
  }

  deinit {
    cleanup?.runOnMain()
  }
}

#if os(Linux) || os(Android)
/// The kernel's power supply class: `/sys/class/power_supply/<name>/{type,scope,capacity,status}`.
enum LinuxPowerSupply {
  static let root = URL(fileURLWithPath: "/sys/class/power_supply")

  static func battery() -> Battery? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
    for name in names.sorted() {
      let folder = root.appendingPathComponent(name)
      // Batteries of a mouse or a keyboard say scope Device; the system's battery has no scope or System.
      guard read(folder, "type") == "Battery", (read(folder, "scope") ?? "System") == "System",
        let capacity = read(folder, "capacity").flatMap(Double.init)
      else { continue }
      let status = read(folder, "status") ?? ""
      // Charging, Full, or Not charging (plugged in but held, e.g. at a charge limit) all mean external power.
      return Battery(level: min(max(capacity / 100, 0), 1), isCharging: status != "Discharging" && status != "Unknown")
    }
    return nil
  }

  static func read(_ folder: URL, _ file: String) -> String? {
    (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
#endif
