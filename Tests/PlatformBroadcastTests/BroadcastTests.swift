import Foundation
import PlatformBroadcast
import Testing

@Suite struct BroadcastTests {
  @Test func deliversToAnObserver() async throws {
    let name = "dev.v57.platform.test.\(UUID().uuidString)"
    let messages = Broadcast.messages(named: name)
    let received = Task { () -> [String: String]? in
      for await info in messages { return info }
      return nil
    }
    // The observer is in place once the stream is iterated.
    try await Task.sleep(for: .milliseconds(300))
    Broadcast.post(name, ["answer": "yes", Broadcast.objectKey: "status"])
    let info = try #require(await withTimeout { await received.value })
    #expect(info == ["answer": "yes", Broadcast.objectKey: "status"])
  }

  private func withTimeout(_ body: @escaping @Sendable () async -> [String: String]?) async -> [String: String]? {
    await withTaskGroup(of: [String: String]?.self) { group in
      group.addTask { await body() }
      group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
