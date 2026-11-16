# PlatformDiskUsage

Disk usage that counts shared blocks once, identical files made into clones, and who may move a file. Part of
[Platform](../README.md).

<!-- platforms: macos ios linux=partial windows=partial android=planned -->

## Purpose

`PlatformDiskUsage` replaces the `fts(3)`, `getattrlist` and `statfs` code a disk-space tool would otherwise write per
platform. It walks file trees the way `du` does (allocated blocks, not logical length, never crossing onto another
volume) and counts a hard link, and the part of an APFS clone shared with its other copies, once per scan instead of
once per path. `du` and Finder count every clone in full, so a disk full of clones adds up to more than the disk
holds. It never downloads cloud-only (dataless) files.

It doesn't delete anything. `DuplicateFiles` makes identical files share their blocks; each copy keeps its path,
extended attributes, mode and dates.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformDiskUsage", package: "Platform"),
```

```swift
import Foundation
import PlatformDiskUsage

let home = NSHomeDirectory()
let ledger = SharedBlockLedger()   // one per scan, shared by every item measured in it
let caches = DiskUsage.measure([home + "/Library/Caches"], ledger: ledger)
let projects = DiskUsage.measure([home + "/Projects"], ledger: ledger)
print(caches.bytes, caches.sharedElsewhere, projects.bytes)
```

The calls block while they walk: run them off the main actor.

## Main API

### DiskUsage

- `measure(_:excluding:ledger:)`: the bytes under some paths, skipping `excluded` subtrees. Returns a `Measurement`:
  `bytes` (its own blocks, plus shared blocks no earlier item counted), `sharedElsewhere` (shared bytes another item
  in the same `ledger` already counted) and `newest` (latest modification time, seconds since 1970). Missing paths
  count as zero. Checks for task cancellation and returns what it had counted when cancelled.
- `directorySizes(of:maxDepth:minBytes:progress:)`: the size of every folder down to `maxDepth` that holds at least
  `minBytes` (what `du -d` prints), plus the folders it couldn't read.
- `walk(_:visit:)`: walks roots depth-first, physically (symbolic links aren't followed) and on one volume. Each
  directory is offered to `visit` before its children; return `.descend` or `.skip` (`DiskUsage.Decision`). The
  `DiskUsage.Entry` is valid only during the visit: `path`, `name`, `level`, `isDirectory`, `isRegularFile`,
  `allocatedBytes`, `logicalBytes`, `linkCount`, `isDataless`, `ownerID`, `hasOnlyCompressionFlags`, `modified`
  (`FileTime`), `cloneInfo`.
- `cloneInfo(atPath:)`: APFS's clone bookkeeping for a file (`CloneInfo`: `privateSize`, `id`, `flags`,
  `maySharesBlocks`), nil where the volume keeps none.
- `SharedBlockLedger()`: the hard links and clone groups one scan has counted, safe to share across items measured
  in parallel.

### DuplicateFiles

- `DuplicateFiles.isSupported`: whether the system can make files clones of each other (APFS: true on Apple
  platforms, false elsewhere).
- `find(in:)`: the identical files under some roots (`Found`: `groups`, `bytes` that cloning would free, `copyCount`).
  Files count as identical only when their contents and extended attributes match. Files under `minimumSize` (16 KB)
  are left out. It reads every file that has a same-sized twin and checks for cancellation between files.
- `cloneAll(in:)`: finds the duplicates and replaces each copy with a clone of one of them (`Result`: `freed`,
  `cloned`, `failures`).

### FileAccess

- `userID`, `groupID`: this process's ids.
- `owner(ofPath:)`: an item's owner id, nil when it doesn't exist.
- `isMovable(_:)`: whether this user may move or delete the item, from ownership and mode bits.
- `volumeCapacity(at:)`: the volume's `total` and `available` bytes.

## Backends

- **macOS**: `fts` and `getattrlist` (APFS clone ids and private sizes), dataless files skipped without downloading;
  `DuplicateFiles` clones with APFS.
- **Linux**: glibc's `fts` (through the internal `CFTS` target), hard links counted once by device and inode; no clone
  bookkeeping. `FileAccess` uses `stat` and `statvfs` (`stat` and URL resource values on the Mac).
- **Windows**: `FindFirstFileExW` walks; a file's allocated size, link count and id (volume serial and file index)
  are read from a handle opened for its attributes, so a hard link counts once. Reparse points (symbolic links,
  junctions, mounted volumes) aren't followed and cloud-only placeholders are never opened. Folders take no space of
  their own. `FileAccess` treats every file as this user's (no ids or groups) and reads the volume with
  `GetDiskFreeSpaceExW`.
- **iOS**: the Darwin code (`fts`, `getattrlist`, APFS clones) without the Mac's no-download policy.
- **Android**: not built or tested.

## Platform notes

- **macOS**: supported, the main target (disk-space tools, simulator cleanup).
- **Linux**: builds; no clones, so `sharedElsewhere` only ever holds hard links, `DuplicateFiles.isSupported` is
  false and `find` finds nothing.
- **Windows**: builds and its tests pass (hard links counted once); no clones, as on Linux.
- **iOS**: builds; untested.

## Testing

```bash
swift test --filter PlatformDiskUsageTests
```

The test makes a file and a hard link to it in a temporary folder and checks the link counts once (on every
platform, Windows included).

## Related

- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
