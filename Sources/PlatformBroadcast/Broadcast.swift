import Foundation

#if os(Linux)
  import Glibc
#endif

/// Messages between the processes of one user on one machine: a name and a few strings, delivered to every process
/// observing that name (an app and its command-line helper, a debug hook driven from a shell). The Mac's
/// `DistributedNotificationCenter`; on Linux a Unix datagram socket per observer in a folder of the user's runtime
/// directory (`$XDG_RUNTIME_DIR/v57-broadcast/<name>/`); nothing is delivered on iOS.
///
/// ```swift
/// let observation = Broadcast.observe("dev.v57.dev.agent.reply") { info in print(info["answer"] ?? "") }
/// Broadcast.post("dev.v57.dev.agent.request", ["id": id, "kind": "ask"])
/// ```
public nonisolated enum Broadcast {
  /// The key a message's `object` (the Mac's notification object, a string such as `notifyutil`-style commands) comes
  /// under in the info a handler gets.
  public static let objectKey = "object"

  /// Sends `info` to every process observing `name`, at once.
  public static func post(_ name: String, _ info: [String: String] = [:]) {
    #if os(macOS)
      var userInfo = info
      let object = userInfo.removeValue(forKey: objectKey)
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name), object: object, userInfo: userInfo.isEmpty ? nil : userInfo,
        deliverImmediately: true)
    #elseif os(Linux)
      SocketBroadcast.post(name, info)
    #endif
  }

  /// Calls `handler` on the main queue with each message posted under `name` until the observation is cancelled or
  /// released.
  public static func observe(_ name: String, handler: @escaping @Sendable ([String: String]) -> Void) -> Observation {
    #if os(macOS)
      let center = DistributedNotificationCenter.default()
      let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
        var info = note.userInfo as? [String: String] ?? [:]
        if let object = note.object as? String { info[objectKey] = object }
        handler(info)
      }
      return Observation { center.removeObserver(token) }
    #elseif os(Linux)
      let listener = SocketBroadcast.Listener(name: name, handler: handler)
      return Observation { listener.stop() }
    #else
      return Observation {}
    #endif
  }

  /// The messages posted under `name`, as they come, while the stream is iterated.
  public static func messages(named name: String) -> AsyncStream<[String: String]> {
    AsyncStream { continuation in
      let observation = observe(name) { continuation.yield($0) }
      continuation.onTermination = { _ in observation.cancel() }
    }
  }

  /// An observer of one name; it stops when cancelled or released.
  public final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var stop: (() -> Void)?

    init(stop: @escaping () -> Void) { self.stop = stop }

    public func cancel() {
      let stop = lock.withLock { () -> (() -> Void)? in
        defer { self.stop = nil }
        return self.stop
      }
      stop?()
    }

    deinit { cancel() }
  }
}

#if os(Linux)
  /// Each observer binds a datagram socket in the name's folder; a post sends one JSON datagram to every socket there
  /// and removes the ones nobody listens on any more.
  nonisolated enum SocketBroadcast {
    static var root: URL {
      let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
      return URL(fileURLWithPath: runtime).appendingPathComponent("v57-broadcast", isDirectory: true)
    }

    static func folder(_ name: String) -> URL {
      root.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    static func post(_ name: String, _ info: [String: String]) {
      guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
      let folder = folder(name)
      guard let sockets = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
      let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
      guard fd >= 0 else { return }
      defer { close(fd) }
      for file in sockets where file.hasSuffix(".sock") {
        let path = folder.appendingPathComponent(file).path
        let sent = withAddress(path) { address, length in
          data.withUnsafeBytes { sendto(fd, $0.baseAddress, data.count, Int32(MSG_DONTWAIT), address, length) }
        }
        if sent < 0, errno == ECONNREFUSED || errno == ENOENT { unlink(path) }
      }
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        let bytes = Array(path.utf8.prefix(buffer.count - 1)) + [0]
        buffer.copyBytes(from: bytes)
      }
      return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
    }

    final class Listener: @unchecked Sendable {
      private let fd: Int32
      private let path: String

      init(name: String, handler: @escaping @Sendable ([String: String]) -> Void) {
        let folder = SocketBroadcast.folder(name)
        try? FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = folder.appendingPathComponent("\(getpid())-\(UUID().uuidString.prefix(8)).sock").path
        fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
        guard fd >= 0 else { return }
        let bound = SocketBroadcast.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else { return }
        let fd = fd
        let thread = Thread {
          var buffer = [UInt8](repeating: 0, count: 64 * 1024)
          while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
              if errno == EINTR { continue }
              return
            }
            guard count > 0 else { continue }
            let data = Data(buffer[0..<count])
            guard let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { continue }
            DispatchQueue.main.async { handler(info) }
          }
        }
        thread.name = "Broadcast \(name)"
        thread.start()
      }

      func stop() {
        unlink(path)
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
      }
    }
  }
#endif
