import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Linux)
  import Glibc
#endif

/// Who owns files and who may move them, read from ownership and mode bits (not `access(2)`, which on the Mac also
/// says no for an app bundle App Management guards: that refusal shows when the move fails), plus the volume's room.
public nonisolated enum FileAccess {
  /// This process's user id.
  public static var userID: UInt32 { UInt32(getuid()) }

  /// This process's primary group id.
  public static var groupID: UInt32 { UInt32(getgid()) }

  /// The user id owning the item at `path` (a symlink itself, not its target); nil when it can't be read.
  public static func owner(ofPath path: String) -> UInt32? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return UInt32(info.st_uid)
  }

  /// Whether this user may move the item at `path` to another folder: the item's folder must be writable and, for a
  /// folder, the folder itself (moving it rewrites its `..`). A missing item counts as movable.
  public static func isMovable(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return true }
    let parent = (path as NSString).deletingLastPathComponent
    guard isWritable(parent) else { return false }
    return (info.st_mode & S_IFMT) != S_IFDIR || isWritable(path)
  }

  private static func isWritable(_ path: String) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0 else { return false }
    if info.st_uid == getuid() { return info.st_mode & S_IWUSR != 0 }
    if userGroups.contains(UInt32(info.st_gid)) { return info.st_mode & S_IWGRP != 0 }
    return info.st_mode & S_IWOTH != 0
  }

  private static let userGroups: Set<UInt32> = {
    var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
    let count = getgroups(Int32(groups.count), &groups)
    return Set(groups.prefix(Int(max(count, 0))).map { UInt32($0) })
  }()

  /// The size of the volume holding `path` and the bytes free on it for what the user asks for (on the Mac,
  /// including what the system would purge to make room).
  public static func volumeCapacity(at path: String) -> (total: Int64, available: Int64) {
    #if canImport(Darwin)
      let values = try? URL(fileURLWithPath: path).resourceValues(
        forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
      return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    #else
      var info = statvfs()
      guard statvfs(path, &info) == 0 else { return (0, 0) }
      let block = Int64(info.f_frsize)
      return (Int64(info.f_blocks) * block, Int64(info.f_bavail) * block)
    #endif
  }
}
