import Foundation
import PlatformDiskUsage
import Testing

@Suite struct DiskUsageTests {
  @Test func countsAHardLinkOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("a.bin")
    try Data(repeating: 7, count: 256 * 1024).write(to: file)
    try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("b.bin"))

    let ledger = SharedBlockLedger()
    let measured = DiskUsage.measure([folder.path], ledger: ledger)
    #expect(measured.bytes >= 256 * 1024)
    #expect(measured.bytes < 2 * 256 * 1024)
    // Another item reaching the same file finds it counted.
    let again = DiskUsage.measure([file.path], ledger: ledger)
    #expect(again.sharedElsewhere >= 256 * 1024)

    var names: [String] = []
    DiskUsage.walk([folder.path]) { entry in
      if !entry.isDirectory { names.append(entry.name) }
      return .descend
    }
    #expect(names.sorted() == ["a.bin", "b.bin"])
    let sizes = DiskUsage.directorySizes(of: folder.path, maxDepth: 64, minBytes: 0)
    #expect(sizes.sizes[folder.path] == measured.bytes)
  }
}
