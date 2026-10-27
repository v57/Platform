import Foundation
import PlatformSystem
import Testing

@MainActor @Test func deviceHasANameAndMemory() {
  #expect(!SystemInfo.deviceName.isEmpty)
  #expect((SystemInfo.memoryUsed() ?? 0) > 0)
  let storage = SystemInfo.storage()
  #expect(storage != nil)
  if let storage { #expect(storage.free <= storage.total) }
}

@Test func cpuLoadIsAFraction() async throws {
  let load = CPULoad()
  #expect(load.usage() == nil)
  try await Task.sleep(nanoseconds: 200_000_000)
  if let usage = load.usage() { #expect((0...1).contains(usage)) }
}
