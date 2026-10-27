import Foundation
import Testing

@testable import PlatformDiscovery

/// Advertises a service of a type made for the run and finds it with a browser on the same machine. Needs the
/// system's mDNS service (mDNSResponder; avahi-daemon on Linux, skipped where its socket is missing).
struct PlatformDiscoveryTests {
  static var hasMDNS: Bool {
    #if os(Linux)
      return FileManager.default.fileExists(atPath: "/run/avahi-daemon/socket")
    #else
      return true
    #endif
  }

  final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var current: T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
  }

  func wait(_ seconds: Double = 15, until condition: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
  }

  @Test(.enabled(if: hasMDNS)) func advertisesAndFinds() async throws {
    let type = "_pdtest\(Int.random(in: 1000...9999))._tcp"
    let advertiser = ServiceAdvertiser(name: "Platform Test", type: type, port: 45678, txt: ["v": "1", "who": "test"])
    let events = Box<[ServiceAdvertiserEvent]>([])
    advertiser.start { event in events.set(events.current + [event]) }
    await wait { !events.current.isEmpty }
    #expect(events.current.first == .registered(name: "Platform Test"))

    let browser = ServiceBrowser(type: type)
    let found = Box<[DiscoveredService]>([])
    browser.start { found.set($0) }
    await wait { found.current.contains { $0.name == "Platform Test" && !$0.addresses.isEmpty } }
    let service = try #require(found.current.first { $0.name == "Platform Test" })
    #expect(service.port == 45678)
    #expect(service.type == type)
    #expect(service.txt == ["v": "1", "who": "test"])
    #expect(!service.hostName.isEmpty)
    #expect(!service.addresses.isEmpty)
    #expect(service.isLocal)

    // Withdrawn: the browser sees it go.
    advertiser.stop()
    await wait { !found.current.contains { $0.name == "Platform Test" } }
    #expect(!found.current.contains { $0.name == "Platform Test" })
    browser.stop()
  }
}
