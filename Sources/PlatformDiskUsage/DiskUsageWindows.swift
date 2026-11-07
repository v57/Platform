#if os(Windows)
  import Foundation
  import WinSDK

  /// The Windows walk: `FindFirstFileExW` lists each folder, and a file's allocated size, link count and id come from
  /// a handle opened only to read its attributes (`GetFileInformationByHandle`, `FileStandardInfo`), the first time a
  /// visitor asks. Reparse points (symbolic links, junctions, mounted volumes) are not followed, so a walk stays on
  /// one volume, and cloud-only files (OneDrive's placeholders) are never opened or listed. Folders count as taking
  /// no space of their own; NTFS keeps small ones inside the file table.
  extension DiskUsage {
    /// One visited file-system entry. Valid only during the visit.
    public struct Entry {
      /// The full path: the root as given, then each name after the root's own separator.
      public let path: String
      /// The last path component.
      public let name: String
      /// Depth below the walk's root (the root itself is 0).
      public let level: Int
      let attributes: DWORD
      public let logicalBytes: Int64
      let lastWrite: FILETIME
      private let handleInfo: HandleInfo

      init(path: String, name: String, level: Int, attributes: DWORD, size: Int64, lastWrite: FILETIME) {
        self.path = path
        self.name = name
        self.level = level
        self.attributes = attributes
        self.logicalBytes = size
        self.lastWrite = lastWrite
        self.handleInfo = HandleInfo(path: path)
      }

      /// The root of a walk, or nil when nothing is there.
      init?(root: String) {
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let found = win32Path(root).withCString(encodedAs: UTF16.self) {
          GetFileAttributesExW($0, GetFileExInfoStandard, &data)
        }
        guard found else { return nil }
        let name = root.split(whereSeparator: isSeparator).last.map(String.init) ?? root
        self.init(
          path: root, name: name, level: 0, attributes: data.dwFileAttributes,
          size: Int64(data.nFileSizeHigh) << 32 | Int64(data.nFileSizeLow), lastWrite: data.ftLastWriteTime)
      }

      /// A folder to descend into: not a reparse point, which would lead off this tree or onto another volume.
      public var isDirectory: Bool {
        attributes & Attribute.directory != 0 && attributes & Attribute.reparsePoint == 0
      }

      public var isRegularFile: Bool {
        attributes & (Attribute.directory | Attribute.reparsePoint | Attribute.device) == 0
      }

      /// A file or folder that lives only in the cloud (OneDrive's placeholders and other cloud files): it takes no
      /// space here, and opening it would download it.
      public var isDataless: Bool {
        attributes & (Attribute.offline | Attribute.recallOnOpen | Attribute.recallOnDataAccess) != 0
      }

      public var allocatedBytes: Int64 {
        if isDirectory || isDataless { return 0 }
        return handleInfo.load()?.allocated ?? logicalBytes
      }

      public var linkCount: Int {
        if isDirectory || isDataless { return 1 }
        return handleInfo.load()?.links ?? 1
      }

      var device: UInt64 { handleInfo.load()?.volume ?? 0 }
      var inode: UInt64 { handleInfo.load()?.index ?? 0 }

      /// The owner's user id: Windows has no numeric ones, so every file is this user's (`FileAccess.userID`).
      public var ownerID: UInt32 { FileAccess.userID }

      /// Always true: only the Mac has BSD flags.
      public var hasOnlyCompressionFlags: Bool { true }

      /// The last modification, to the 100 nanoseconds Windows keeps.
      public var modified: FileTime { FileTime(lastWrite) }

      var modifiedSeconds: Int { modified.seconds }

      /// Always nil: only APFS keeps clone bookkeeping.
      public var cloneInfo: CloneInfo? { nil }
    }

    /// What a handle says about a file, read once on first use.
    final class HandleInfo {
      struct Values {
        var allocated: Int64
        var links: Int
        var volume: UInt64
        var index: UInt64
      }

      private let path: String
      private var loaded = false
      private var values: Values?

      init(path: String) { self.path = path }

      func load() -> Values? {
        if loaded { return values }
        loaded = true
        // Opened for its attributes only, sharing everything, so a file another program holds open is still read.
        let handle = win32Path(path).withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0, DWORD(FILE_READ_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        let logical = Int64(info.nFileSizeHigh) << 32 | Int64(info.nFileSizeLow)
        var standard = FILE_STANDARD_INFO()
        let allocated =
          GetFileInformationByHandleEx(
            handle, FileStandardInfo, &standard, DWORD(MemoryLayout<FILE_STANDARD_INFO>.size))
          ? standard.AllocationSize.QuadPart : logical
        values = Values(
          allocated: allocated, links: Int(info.nNumberOfLinks), volume: UInt64(info.dwVolumeSerialNumber),
          index: UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow))
        return values
      }
    }

    /// `FILE_ATTRIBUTE_*`, as `DWORD`s.
    enum Attribute {
      static let readOnly: DWORD = 0x1
      static let directory: DWORD = 0x10
      static let device: DWORD = 0x40
      static let reparsePoint: DWORD = 0x400
      static let offline: DWORD = 0x1000
      static let recallOnOpen: DWORD = 0x40000
      static let recallOnDataAccess: DWORD = 0x400000
    }

    static func directorySizesWalk(
      of root: String, maxDepth: Int, minBytes: Int64, progress: ((Int64) -> Void)?
    ) -> (sizes: [String: Int64], denied: [String]) {
      let rootDepth = root.split(whereSeparator: isSeparator).count
      var sizes: [String: Int64] = [:]
      var denied: [String] = []
      var accounting = SharedAccounting(ledger: SharedBlockLedger())
      // The running total of each open folder, indexed by its level.
      var totals: [Int64] = []
      var counted: Int64 = 0

      traverse(
        root,
        tick: { progress?(counted) },
        visit: { entry in
          if entry.isDirectory {
            // Skipped folders are not left either, so nothing is pushed.
            if entry.isDataless { return .skip }
            totals.removeSubrange(min(entry.level, totals.count)...)
            totals.append(entry.allocatedBytes)
            return .descend
          }
          let bytes = accounting.count(entry).bytes
          counted += bytes
          if entry.level > 0, entry.level - 1 < totals.count {
            totals[entry.level - 1] += bytes
          }
          return .descend
        },
        leave: { entry, refused in
          if refused { denied.append(entry.path) }
          let level = entry.level
          guard level < totals.count else { return }
          let total = totals[level]
          totals.removeSubrange(level...)
          if level > 0 { totals[level - 1] += total }
          if level == 0 || (rootDepth + level <= maxDepth && total >= minBytes) {
            sizes[entry.path] = total
          }
        })
      return (sizes, denied)
    }

    static func walkTree(_ roots: [String], visit: (Entry) -> Decision) {
      for root in roots {
        let finished = traverse(
          root, tick: nil,
          visit: { entry in
            if entry.isDirectory, entry.isDataless { return .skip }
            return visit(entry)
          },
          leave: { _, _ in })
        if !finished { return }
      }
    }

    /// Walks one root depth-first: `visit` sees each entry, a folder before its children (`.skip` prunes it), and
    /// `leave` sees each folder it descended into after its children, with whether listing it was refused. Checks
    /// for task cancellation as it goes (calling `tick` at the same points) and returns false when cancelled.
    @discardableResult
    static func traverse(
      _ root: String, tick: (() -> Void)?, visit: (Entry) -> Decision, leave: (Entry, _ refused: Bool) -> Void
    ) -> Bool {
      guard let top = Entry(root: root) else { return true }
      let separator = root.contains("\\") || !root.contains("/") ? "\\" : "/"
      var visited = 0
      var cancelled = false

      func go(_ entry: Entry) {
        visited += 1
        if visited & 0xFFF == 0 {
          if Task.isCancelled {
            cancelled = true
            return
          }
          tick?()
        }
        guard visit(entry) == .descend, entry.isDirectory else { return }
        let prefix = entry.path.last.map { isSeparator($0) } == true ? entry.path : entry.path + separator
        var data = WIN32_FIND_DATAW()
        let handle = win32Path(prefix + "*").withCString(encodedAs: UTF16.self) {
          FindFirstFileExW(
            $0, FindExInfoBasic, &data, FindExSearchNameMatch, nil, DWORD(FIND_FIRST_EX_LARGE_FETCH))
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
          leave(entry, GetLastError() == DWORD(ERROR_ACCESS_DENIED))
          return
        }
        defer { FindClose(handle) }
        repeat {
          let name = withUnsafeBytes(of: data.cFileName) {
            String(decodingCString: $0.baseAddress!.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
          }
          if name == "." || name == ".." { continue }
          go(
            Entry(
              path: prefix + name, name: name, level: entry.level + 1, attributes: data.dwFileAttributes,
              size: Int64(data.nFileSizeHigh) << 32 | Int64(data.nFileSizeLow), lastWrite: data.ftLastWriteTime))
          if cancelled { return }
        } while FindNextFileW(handle, &data)
        leave(entry, false)
      }

      go(top)
      return !cancelled
    }
  }

  extension DiskUsage.FileTime {
    /// A `FILETIME` (100-nanosecond ticks since 1601) as time since 1970.
    init(_ time: FILETIME) {
      let ticks = Int64(time.dwHighDateTime) << 32 | Int64(time.dwLowDateTime)
      let since1970 = ticks - 116_444_736_000_000_000
      let (seconds, remainder) = since1970.quotientAndRemainder(dividingBy: 10_000_000)
      if remainder < 0 {
        self.init(seconds: Int(seconds) - 1, nanoseconds: Int(remainder + 10_000_000) * 100)
      } else {
        self.init(seconds: Int(seconds), nanoseconds: Int(remainder) * 100)
      }
    }
  }

  func isSeparator(_ character: Character) -> Bool { character == "/" || character == "\\" }

  /// `path` as the wide-character APIs take it: backslashes, and the `\\?\` prefix past the 260-character limit.
  func win32Path(_ path: String) -> String {
    let native = path.replacingOccurrences(of: "/", with: "\\")
    guard native.utf16.count >= 240, !native.hasPrefix("\\\\?\\") else { return native }
    if native.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + native.dropFirst(2) }
    return "\\\\?\\" + native
  }

  /// The attributes of the item at `path` (a link itself, not its target), or nil when nothing is there.
  func fileAttributes(atPath path: String) -> DWORD? {
    let attributes = win32Path(path).withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
    return attributes == INVALID_FILE_ATTRIBUTES ? nil : attributes
  }
#endif
