import Foundation
import PlatformHTTP
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
#elseif os(Linux)
  import Glibc
#endif

@Suite struct HTTPBytesTests {
  static let body = "data: one\r\ndata: two\n\nlast"

  /// Lines with every kind of break, and the bytes as they are, from a server on the loopback.
  @Test func readsLinesAndBytes() async throws {
    let server = try #require(OneShotServer(response: Self.body, count: 2))
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
    let (body, response) = try await HTTPBytes.response(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    var lines: [String] = []
    for try await line in body.lines { lines.append(line) }
    #expect(lines.filter { !$0.isEmpty } == ["data: one", "data: two", "last"])
    let (again, _) = try await HTTPBytes.response(for: request)
    var count = 0
    for try await _ in again { count += 1 }
    #expect(count == Self.body.utf8.count)
  }
}

/// Answers `count` requests on a loopback port with one fixed body.
final class OneShotServer: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init?(response: String, count: Int) {
    #if canImport(Darwin)
      let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
      let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return nil }
    self.fd = fd
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(fd, 4) == 0 else { return nil }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin_port)
    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(response.utf8.count)\r\n"
      + "Connection: close\r\n\r\n" + response
    Thread {
      for _ in 0..<count {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(client, &buffer, buffer.count)
        _ = reply.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
        close(client)
      }
      close(fd)
    }.start()
  }
}
