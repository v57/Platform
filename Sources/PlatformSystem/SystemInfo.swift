import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(UIKit)
import UIKit
#endif

/// What the device is and how busy it is, for apps that report it (Hub's device descriptions): its name, model, CPU,
/// memory and storage. Mach and sysctl on Apple platforms, /proc and /sys on Linux.
public enum SystemInfo {
  /// The name the user gave this device: macOS's computer name, iOS's device name, Linux's pretty host name
  /// (`hostnamectl --pretty`), else the host name.
  @MainActor public static var deviceName: String {
    #if os(macOS)
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #elseif canImport(UIKit) && !os(watchOS)
    UIDevice.current.name
    #elseif os(Linux)
    machineInfo("PRETTY_HOSTNAME") ?? hostName
    #else
    hostName
    #endif
  }

  /// The host name without its domain
  public static var hostName: String {
    let name = ProcessInfo.processInfo.hostName
    return name.split(separator: ".").first.map(String.init) ?? name
  }

  /// The operating system's version: `26.1` (macOS, iOS), a Linux distribution's `VERSION_ID` from os-release
  /// (`24.04`; the kernel's version when there is none), Windows' `10.0.26100`.
  public static var osVersion: String {
    #if os(Linux)
    if let release = read("/etc/os-release") ?? read("/usr/lib/os-release"),
      let line = release.split(separator: "\n").first(where: { $0.hasPrefix("VERSION_ID=") })
    {
      let value = line.dropFirst("VERSION_ID=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
      if !value.isEmpty { return value }
    }
    #endif
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
  }

  /// The hardware model: `Mac15,9`, `iPhone17,1` (the simulated one in the Simulator), a Linux machine's DMI product
  /// or device-tree model (`Raspberry Pi 5 Model B`); `nil` when the system doesn't say.
  public static var model: String? {
    #if targetEnvironment(simulator)
    ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? sysctl("hw.machine")
    #elseif os(macOS)
    sysctl("hw.model")
    #elseif canImport(Darwin)
    sysctl("hw.machine")
    #elseif os(Linux)
    ["/proc/device-tree/model", "/sys/devices/virtual/dmi/id/product_name"].lazy.compactMap { read($0) }.first
    #else
    nil
    #endif
  }

  /// The CPU's marketing name (`Apple M3 Pro`, `Cortex-A76`), when the system says
  public static var cpuModel: String? {
    #if canImport(Darwin)
    sysctl("machdep.cpu.brand_string")
    #elseif os(Linux)
    guard let info = read("/proc/cpuinfo") else { return nil }
    for key in ["model name", "Model", "Hardware"] {
      for line in info.split(separator: "\n") where line.hasPrefix(key) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return value }
      }
    }
    return nil
    #else
    nil
    #endif
  }

  /// Memory in use in bytes: active, wired and compressed pages on Apple platforms, total minus available on Linux
  public static func memoryUsed() -> Int64? {
    #if canImport(Darwin)
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return pages * Int64(getpagesize())
    #elseif os(Linux)
    guard let info = read("/proc/meminfo") else { return nil }
    func kilobytes(_ key: String) -> Int64? {
      guard let line = info.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") }) else { return nil }
      return line.split(separator: " ").dropFirst().first.flatMap { Int64($0) }
    }
    guard let total = kilobytes("MemTotal"), let available = kilobytes("MemAvailable") else { return nil }
    return (total - available) * 1024
    #else
    nil
    #endif
  }

  /// Free and total bytes of the volume holding the home folder. Free counts what the system can make room for
  /// (purgeable space) on Apple platforms.
  public static func storage() -> (free: Int64, total: Int64)? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    #if os(tvOS)
    guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
      let total = values.volumeTotalCapacity
    else { return nil }
    return (Int64(values.volumeAvailableCapacity ?? 0), Int64(total))
    #elseif canImport(Darwin)
    guard
      let values = try? url.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
      ]),
      let total = values.volumeTotalCapacity
    else { return nil }
    return (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(total))
    #elseif os(Linux)
    var stats = statvfs()
    guard statvfs(url.path, &stats) == 0 else { return nil }
    let block = Int64(stats.f_frsize)
    return (Int64(stats.f_bavail) * block, Int64(stats.f_blocks) * block)
    #else
    return nil
    #endif
  }

  /// How hot the device runs, as the system rates it: ProcessInfo's thermal state on Apple platforms; on Linux the
  /// hottest thermal zone against its passive, hot and critical trip points
  public static var thermalState: ThermalState {
    #if canImport(Darwin)
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .nominal
    }
    #elseif os(Linux)
    var state = ThermalState.nominal
    let root = "/sys/class/thermal"
    for zone in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where zone.hasPrefix("thermal_zone") {
      let folder = root + "/" + zone
      guard let temperature = read(folder + "/temp").flatMap(Int.init) else { continue }
      for index in 0..<16 {
        guard let type = read(folder + "/trip_point_\(index)_type") else { break }
        guard let trip = read(folder + "/trip_point_\(index)_temp").flatMap(Int.init), trip > 0, temperature >= trip
        else { continue }
        let reached: ThermalState = type == "critical" ? .critical : type == "hot" ? .serious : type == "passive" ? .fair : .nominal
        if reached.rank > state.rank { state = reached }
      }
    }
    return state
    #else
    return .nominal
    #endif
  }

  #if canImport(Darwin)
  static func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    let string = String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return string.isEmpty ? nil : string
  }
  #endif

  #if os(Linux)
  /// A small text file, trimmed (device-tree strings end in NUL)
  static func read(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// A value of /etc/machine-info, which `hostnamectl` writes
  static func machineInfo(_ key: String) -> String? {
    guard let info = read("/etc/machine-info") else { return nil }
    for line in info.split(separator: "\n") where line.hasPrefix(key + "=") {
      var value = line.dropFirst(key.count + 1)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
      if !value.isEmpty { return String(value) }
    }
    return nil
  }
  #endif
}

/// How hot the device runs
public enum ThermalState: String, Sendable, Hashable {
  case nominal, fair, serious, critical

  var rank: Int {
    switch self {
    case .nominal: 0
    case .fair: 1
    case .serious: 2
    case .critical: 3
    }
  }
}

/// The share of time the CPUs were busy between two samples.
public final class CPULoad: @unchecked Sendable {
  private let lock = NSLock()
  private var previous: (busy: Double, total: Double)?

  public init() {}

  /// Busy share since the previous call, 0...1; `nil` on the first call
  public func usage() -> Double? {
    guard let now = Self.ticks() else { return nil }
    let before: (busy: Double, total: Double)? = lock.withLock {
      defer { previous = now }
      return previous
    }
    guard let before else { return nil }
    let total = now.total - before.total
    guard total > 0 else { return nil }
    return min(max((now.busy - before.busy) / total, 0), 1)
  }

  private static func ticks() -> (busy: Double, total: Double)? {
    #if canImport(Darwin)
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = Double(info.cpu_ticks.0), system = Double(info.cpu_ticks.1)
    let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
    return (user + system + nice, user + system + idle + nice)
    #elseif os(Linux)
    // cpu  user nice system idle iowait irq softirq steal ...
    guard let stat = SystemInfo.read("/proc/stat"), let line = stat.split(separator: "\n").first,
      line.hasPrefix("cpu ")
    else { return nil }
    let values = line.split(separator: " ").dropFirst().compactMap { Double($0) }
    guard values.count >= 4 else { return nil }
    let idle = values[3] + (values.count > 4 ? values[4] : 0)
    let total = values.prefix(8).reduce(0, +)
    return (total - idle, total)
    #else
    return nil
    #endif
  }
}
