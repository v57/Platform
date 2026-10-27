import Foundation

#if canImport(Network)
import Network
#endif

/// How the device reaches the network now.
public enum NetworkInterfaceKind: String, Sendable, Hashable {
  case wifi, cellular, ethernet, other
}

/// The kind of network the device uses now. Network.framework's path monitor on Apple platforms; on Linux the
/// interface of the default route, read when asked (/proc/net/route and /sys/class/net).
public final class NetworkMonitor: @unchecked Sendable {
  public static let shared = NetworkMonitor()

  #if canImport(Network)
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var path: NWPath?
  #endif

  public init() {
    #if canImport(Network)
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      lock.withLock { self.path = path }
    }
    monitor.start(queue: DispatchQueue(label: "dev.v57.Platform.network"))
    #endif
  }

  deinit {
    #if canImport(Network)
    monitor.cancel()
    #endif
  }

  /// The interface kind in use, `nil` while offline
  public var interface: NetworkInterfaceKind? {
    #if canImport(Network)
    guard let path = lock.withLock({ path }), path.status == .satisfied else { return nil }
    if path.usesInterfaceType(.wifi) { return .wifi }
    if path.usesInterfaceType(.cellular) { return .cellular }
    if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
    return .other
    #elseif os(Linux)
    guard let name = Self.defaultRouteInterface() else { return nil }
    let folder = "/sys/class/net/\(name)"
    if FileManager.default.fileExists(atPath: folder + "/wireless") || FileManager.default.fileExists(atPath: folder + "/phy80211") {
      return .wifi
    }
    if name.hasPrefix("wwan") || name.hasPrefix("rmnet") { return .cellular }
    // ARPHRD_ETHER, and a physical device (virtual ones like bridges and tunnels have none)
    let type = (try? String(contentsOfFile: folder + "/type", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    if type == "1", FileManager.default.fileExists(atPath: folder + "/device") { return .ethernet }
    return .other
    #else
    return nil
    #endif
  }

  #if os(Linux)
  /// The interface of the IPv4 default route (destination 00000000), else of an IPv6 one
  static func defaultRouteInterface() -> String? {
    if let routes = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) {
      for line in routes.split(separator: "\n").dropFirst() {
        let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
        if fields.count > 1, fields[1] == "00000000" { return String(fields[0]) }
      }
    }
    if let routes = try? String(contentsOfFile: "/proc/net/ipv6_route", encoding: .utf8) {
      for line in routes.split(separator: "\n") {
        let fields = line.split(separator: " ")
        if fields.count == 10, fields[0] == String(repeating: "0", count: 32), fields[1] == "00", fields[9] != "lo" {
          return String(fields[9])
        }
      }
    }
    return nil
  }
  #endif
}
