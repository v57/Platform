import Foundation

/// A DNS-SD (Bonjour, mDNS) service found on the local network, resolved to its host and port.
public struct DiscoveredService: Identifiable, Hashable, Sendable {
  /// The instance name ("Ann's Mac").
  public var name: String
  /// The service type ("_v57remote._udp").
  public var type: String
  /// The domain ("local").
  public var domain: String
  /// The host it runs on ("anns-mac.local").
  public var hostName: String
  public var port: UInt16
  /// The host's numeric addresses as found so far, IPv4 first (IPv6 link-local ones with their `%interface`).
  public var addresses: [String]
  /// The TXT record's keys and values.
  public var txt: [String: String]
  /// The network interface it was seen on (the system's index), when the backend tells.
  public var interfaceIndex: UInt32?
  /// Published by this machine.
  public var isLocal: Bool

  public var id: String { "\(name).\(type).\(domain)" }

  public init(
    name: String, type: String, domain: String, hostName: String, port: UInt16, addresses: [String] = [],
    txt: [String: String] = [:], interfaceIndex: UInt32? = nil, isLocal: Bool = false
  ) {
    self.name = name
    self.type = type
    self.domain = domain
    self.hostName = hostName
    self.port = port
    self.addresses = addresses
    self.txt = txt
    self.interfaceIndex = interfaceIndex
    self.isLocal = isLocal
  }
}

/// What a `ServiceAdvertiser` reports.
public enum ServiceAdvertiserEvent: Equatable, Sendable {
  /// On the network under `name` (the one asked for, or another when it was taken).
  case registered(name: String)
  /// Not advertised: no mDNS service on this machine (avahi-daemon), or it refused.
  case failed(String)
}

/// Lists the services of one type on the local network as they come and go (each resolved to a host and port):
/// dns_sd on Apple platforms, the avahi-daemon on Linux (none found, without an error, where it doesn't run).
///
/// ```swift
/// let browser = ServiceBrowser(type: "_v57remote._udp")
/// browser.start { services in … }   // on a queue of its own
/// ```
public final class ServiceBrowser: @unchecked Sendable {
  public let type: String
  public let domain: String?
  /// Apple platforms: also over peer-to-peer links (AWDL).
  public var includesPeerToPeer = false
  let backend: BrowserBackend

  public init(type: String, domain: String? = nil) {
    self.type = type
    self.domain = domain
    backend = BrowserBackend()
  }

  /// Starts browsing; `onChange` gets the whole list (sorted by name) whenever it changes, on a background queue.
  public func start(onChange: @escaping @Sendable ([DiscoveredService]) -> Void) {
    backend.start(type: type, domain: domain, peerToPeer: includesPeerToPeer, onChange: onChange)
  }

  public func stop() { backend.stop() }

  deinit { backend.stop() }
}

/// Advertises one service on the local network until stopped: dns_sd on Apple platforms, the avahi-daemon on Linux.
public final class ServiceAdvertiser: @unchecked Sendable {
  public let name: String?
  public let type: String
  public let port: UInt16
  public let txt: [String: String]
  let backend: AdvertiserBackend

  /// `name` nil takes the machine's name.
  public init(name: String?, type: String, port: UInt16, txt: [String: String] = [:]) {
    self.name = name
    self.type = type
    self.port = port
    self.txt = txt
    backend = AdvertiserBackend()
  }

  public func start(onEvent: (@Sendable (ServiceAdvertiserEvent) -> Void)? = nil) {
    backend.start(name: name ?? Self.machineName, type: type, port: port, txt: txt, onEvent: onEvent ?? { _ in })
  }

  public func stop() { backend.stop() }

  deinit { backend.stop() }

  /// The name services get by default: the host name without its domain.
  public static var machineName: String {
    let host = ProcessInfo.processInfo.hostName
    return host.split(separator: ".").first.map(String.init) ?? host
  }
}

/// The services seen so far, merged from instances per interface and protocol.
struct ServiceTable {
  struct Instance: Hashable {
    var name: String
    var type: String
    var domain: String
    var interface: Int32
    var proto: Int32
  }
  var resolved: [Instance: DiscoveredService] = [:]

  /// One entry per service id, addresses merged, IPv4 first.
  var services: [DiscoveredService] {
    var byID: [String: DiscoveredService] = [:]
    for (_, service) in resolved.sorted(by: { $0.key.interface < $1.key.interface }) {
      if var existing = byID[service.id] {
        for address in service.addresses where !existing.addresses.contains(address) { existing.addresses.append(address) }
        existing.isLocal = existing.isLocal || service.isLocal
        byID[service.id] = existing
      } else {
        byID[service.id] = service
      }
    }
    return byID.values.map { service in
      var service = service
      service.addresses.sort { ($0.contains(":") ? 1 : 0, $0) < ($1.contains(":") ? 1 : 0, $1) }
      return service
    }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
  }
}
