import Foundation

#if canImport(Darwin)
  import CryptoKit
  import Darwin
#endif

/// Identical files under some folders, made into clones of one copy (APFS clones on the Mac; none elsewhere yet:
/// `isSupported` is false and `find` finds nothing). Simulators are where this pays: every device renders the same
/// wallpapers, downloads the same system assets and keeps old renders of both, so their data folders are mostly the
/// same files many times over.
///
/// Nothing is removed. Each copy keeps its path, extended attributes, mode and dates and only shares its blocks with
/// the others; whichever copy is written to later gets its own blocks back. Copies count as identical only when their
/// contents and extended attributes both match, so a clone (which takes the attributes of the copy it was cloned
/// from) is the file it replaces.
public nonisolated enum DuplicateFiles {
  /// Smaller files cost more to hash than cloning them gives back.
  public static let minimumSize: Int64 = 16 * 1024

  /// Whether this system can make files clones of each other (the Mac's APFS).
  public static var isSupported: Bool {
    #if canImport(Darwin)
      true
    #else
      false
    #endif
  }

  /// One file seen by the walk.
  public struct File: Sendable {
    public let path: String
    public let size: Int64
    public let allocated: Int64
    public let modified: DiskUsage.FileTime
  }

  /// Identical files: the copy the others become clones of, and the copies
  /// that take space of their own with what replacing each frees.
  public struct Group: Sendable {
    public let source: File
    public let copies: [(file: File, freed: Int64)]
  }

  public struct Found: Sendable {
    public var groups: [Group] = []
    public var bytes: Int64 { groups.reduce(0) { $0 + $1.copies.reduce(0) { $0 + $1.freed } } }
    public var copyCount: Int { groups.reduce(0) { $0 + $1.copies.count } }
  }

  public struct Result: Sendable {
    public var freed: Int64 = 0
    public var cloned = 0
    public var failures: [String] = []
  }

  // MARK: Finding

  /// The identical files under `roots` whose copies could share blocks. Reads
  /// every file that has a same-sized twin, so it takes as long as reading
  /// those; checks for task cancellation between files.
  public static func find(in roots: [String]) -> Found {
    guard isSupported else { return Found() }
    let owner = UInt32(getuid())
    var bySize: [Int64: [File]] = [:]
    DiskUsage.walk(roots) { entry in
      guard !entry.isDirectory else { return .descend }
      // Only plain files this account owns with one name: a hard link would
      // be split from its other names, a locked or other user's file can't
      // be replaced. Compression is a flag too, and clones keep it.
      guard entry.isRegularFile, entry.linkCount == 1, entry.ownerID == owner,
        entry.hasOnlyCompressionFlags, entry.logicalBytes >= minimumSize
      else { return .descend }
      let file = File(path: entry.path, size: entry.logicalBytes, allocated: entry.allocatedBytes,
        modified: entry.modified)
      bySize[file.size, default: []].append(file)
      return .descend
    }

    // Hashing is most of the time: spread over the cores in batches, with a
    // check for cancellation between batches.
    let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
    // Each worker writes only its own slot.
    nonisolated(unsafe) let keys = UnsafeMutableBufferPointer<Data?>.allocate(capacity: candidates.count)
    keys.initialize(repeating: nil)
    defer {
      _ = keys.deinitialize()
      keys.deallocate()
    }
    for start in stride(from: 0, to: candidates.count, by: 128) {
      guard !Task.isCancelled else { return Found() }
      let batch = start..<min(start + 128, candidates.count)
      DispatchQueue.concurrentPerform(iterations: batch.count) { offset in
        let index = batch.lowerBound + offset
        keys[index] = identity(of: candidates[index].path)
      }
    }

    var byContent: [Data: [File]] = [:]
    for (file, key) in zip(candidates, keys) {
      guard let key else { continue }
      byContent[withUnsafeBytes(of: file.size) { Data($0) } + key, default: []].append(file)
    }
    var found = Found()
    for files in byContent.values where files.count > 1 {
      if let group = group(files) { found.groups.append(group) }
    }
    return found
  }

  #if canImport(Darwin)
  /// Picks the copy most others already share blocks with as the source, so
  /// copies that are clones already are left alone, and works out what
  /// replacing each other copy frees: the blocks it holds on its own.
  private static func group(_ files: [File]) -> Group? {
    let clones = files.map { DiskUsage.cloneInfo(atPath: $0.path) }
    func cloneID(_ index: Int) -> UInt64? {
      guard let info = clones[index], info.maySharesBlocks else { return nil }
      return info.id
    }
    var counts: [UInt64: Int] = [:]
    for index in files.indices { if let id = cloneID(index) { counts[id, default: 0] += 1 } }
    let shared = counts.max { $0.value < $1.value }?.key
    let sourceIndex = files.indices.first { shared != nil && cloneID($0) == shared } ?? 0

    var copies: [(file: File, freed: Int64)] = []
    for index in files.indices where index != sourceIndex {
      if let shared, cloneID(index) == shared { continue }
      let file = files[index]
      let freed = cloneID(index) != nil
        ? min(file.allocated, max(0, clones[index]?.privateSize ?? 0)) : file.allocated
      if freed > 0 { copies.append((file, freed)) }
    }
    return copies.isEmpty ? nil : Group(source: files[sourceIndex], copies: copies)
  }

  /// SHA-256 of the contents followed by SHA-256 of the extended attributes,
  /// or nil when the file can't be read.
  private static func identity(of path: String) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    // The data is read once and not needed again: keep it out of the cache.
    _ = fcntl(fd, F_NOCACHE, 1)
    var content = SHA256()
    let chunk = 1 << 20
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
    defer { buffer.deallocate() }
    while true {
      let count = read(fd, buffer.baseAddress, chunk)
      if count < 0 { return nil }
      if count == 0 { break }
      content.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
    }
    var attributes = SHA256()
    for (name, value) in extendedAttributes(fd) {
      attributes.update(data: Data(name.utf8) + [0] + value + [0])
    }
    return Data(content.finalize()) + Data(attributes.finalize())
  }

  private static func extendedAttributes(_ fd: Int32) -> [(String, Data)] {
    let length = flistxattr(fd, nil, 0, 0)
    guard length > 0 else { return [] }
    var names = [CChar](repeating: 0, count: length)
    guard flistxattr(fd, &names, length, 0) == length else { return [] }
    let list = names.split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }
    return list.sorted().map { name in
      let size = fgetxattr(fd, name, nil, 0, 0, 0)
      guard size > 0 else { return (name, Data()) }
      var value = Data(count: size)
      let read = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
      return (name, read == size ? value : Data())
    }
  }

  #endif

  // MARK: Cloning

  /// Finds the identical files under `roots` again (what a scan saw may be
  /// stale) and replaces every copy with a clone of its group's source.
  /// `~/…` for paths in the home folder.
  private static func abbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  public static func cloneAll(in roots: [String]) -> Result {
    var result = Result()
    for group in find(in: roots).groups {
      for (file, freed) in group.copies {
        guard !Task.isCancelled else { return result }
        do {
          try replace(file, withCloneOf: group.source)
          result.cloned += 1
          result.freed += freed
        } catch {
          result.failures.append("\(abbreviated(file.path)): \(error.localizedDescription)")
        }
      }
    }
    return result
  }

  #if canImport(Darwin)
  /// Clones `source` next to `file`, gives the clone the file's mode and
  /// dates, and renames it over the file: the path is never missing, and a
  /// failure leaves the file as it was.
  private static func replace(_ file: File, withCloneOf source: File) throws {
    var info = stat()
    // Changed since it was hashed: leave it for the next scan.
    guard lstat(file.path, &info) == 0, info.st_size == file.size,
      DiskUsage.FileTime(info.st_mtimespec) == file.modified
    else { throw Failure(message: "changed since it was read") }
    let url = URL(fileURLWithPath: file.path)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent("." + url.lastPathComponent + ".dev-clone").path
    unlink(temporary)
    guard clonefile(source.path, temporary, UInt32(CLONE_NOFOLLOW)) == 0 else { throw Failure.errno() }
    do {
      guard chmod(temporary, info.st_mode & 0o7777) == 0 else { throw Failure.errno() }
      var times = [info.st_atimespec, info.st_mtimespec]
      guard utimensat(AT_FDCWD, temporary, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.errno() }
      var created = URLResourceValues()
      created.creationDate = Date(timeIntervalSince1970:
        TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9)
      var clone = URL(fileURLWithPath: temporary)
      try? clone.setResourceValues(created)
      guard rename(temporary, file.path) == 0 else { throw Failure.errno() }
    } catch {
      unlink(temporary)
      throw error
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func errno() -> Failure { Failure(message: String(cString: strerror(Darwin.errno))) }
  }
  #else
    private static func group(_ files: [File]) -> Group? { nil }
    private static func identity(of path: String) -> Data? { nil }
    private static func replace(_ file: File, withCloneOf source: File) throws {
      throw CocoaError(.featureUnsupported)
    }
  #endif
}
