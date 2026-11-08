import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// v57/Localizations' `manifest.json`: every source's languages and their files.
///
/// Language codes and file names become paths (`<source>/<lang>.lproj/<name>`, here and in Application Support), so
/// one that isn't a language code or a `.strings`/`.stringsdict` name is dropped when the manifest is read
/// (`isLanguageCode`, `isFileName`; Code's release-languages refuses the same ones at release).
struct Manifest: Decodable, Sendable {
  struct File: Decodable, Hashable, Sendable {
    let bytes: Int
    let sha256: String
  }

  let version: Int
  /// source → language → file name → file.
  let sources: [String: [String: [String: File]]]

  init(version: Int, sources: [String: [String: [String: File]]]) {
    self.version = version
    self.sources = sources.filter { Self.isSourceName($0.key) }.mapValues { languages in
      languages.filter { Self.isLanguageCode($0.key) }.mapValues { files in files.filter { Self.isFileName($0.key) } }
    }
  }

  init(from decoder: any Decoder) throws {
    enum Keys: String, CodingKey { case version, sources }
    let container = try decoder.container(keyedBy: Keys.self)
    self.init(
      version: try container.decode(Int.self, forKey: .version),
      sources: try container.decode([String: [String: [String: File]]].self, forKey: .sources))
  }

  /// "de", "pt-BR", "zh-Hans": `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$`.
  static func isLanguageCode(_ code: String) -> Bool {
    let parts = code.split(separator: "-", omittingEmptySubsequences: false)
    guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLowercase })
    else { return false }
    return parts.dropFirst().allSatisfy { part in
      (2...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
  }

  /// "Localizable.strings", "Localizable.stringsdict": `^[A-Za-z0-9_+-]+\.(strings|stringsdict)$`.
  static func isFileName(_ name: String) -> Bool {
    guard let dot = name.lastIndex(of: "."), [".strings", ".stringsdict"].contains(String(name[dot...])) else {
      return false
    }
    return isSourceName(String(name[..<dot]))
  }

  /// A source's (a bundle's) name: `^[A-Za-z0-9_+-]+$`.
  static func isSourceName(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
  }

  /// `code`'s files for `sources`, in their order.
  func files(of code: String, in sources: [String]) -> [PackFile] {
    sources.flatMap { source in
      (self.sources[source]?[code] ?? [:]).sorted { $0.key < $1.key }.map {
        PackFile(source: source, name: $0.key, bytes: $0.value.bytes, sha256: $0.value.sha256)
      }
    }
  }

  /// The languages any of `sources` has.
  func languages(in sources: [String]) -> Set<String> {
    Set(sources.flatMap { self.sources[$0]?.keys.map { $0 } ?? [] })
  }
}

/// One file of a language: `<source>/<lang>.lproj/<name>`.
struct PackFile: Hashable, Sendable {
  let source: String
  let name: String
  let bytes: Int
  let sha256: String
}

extension Array where Element == PackFile {
  var bytes: Int { reduce(0) { $0 + $1.bytes } }
  /// "Source/Localizable.strings" → SHA-256: what tells an update.
  var hashes: [String: String] {
    Dictionary(map { ("\($0.source)/\($0.name)", $0.sha256) }, uniquingKeysWith: { first, _ in first })
  }
}

/// Where downloaded languages live: `<root>/<lang>/<folder>/<source>/<lang>.lproj/…` with `<root>/<lang>/state.json`
/// naming the current folder. Each download gets a new folder, since Foundation keeps a bundle's tables by its path.
struct PackStore: Sendable {
  let root: URL

  struct Saved: Codable, Equatable {
    var folder: String
    var bytes: Int
    var hashes: [String: String]
  }

  /// Application Support (`~/.local/share`, `%APPDATA%`) / the app's bundle identifier / Languages.
  static var defaultRoot: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    return support.appendingPathComponent(app).appendingPathComponent("Languages")
  }

  func state(of code: String) -> Saved? {
    let file = root.appendingPathComponent(code).appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
      FileManager.default.fileExists(atPath: root.appendingPathComponent(code).appendingPathComponent(saved.folder).path)
    else { return nil }
    return saved
  }

  func downloaded() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { state(of: $0) != nil }.sorted()
  }

  /// An empty folder for a download of `code`.
  func newFolder(for code: String) throws -> URL {
    let folder = root.appendingPathComponent(code).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Makes `folder` (from `newFolder`) `code`'s current files and deletes the ones before.
  func install(_ folder: URL, language code: String, files: [PackFile]) throws {
    let saved = Saved(folder: folder.lastPathComponent, bytes: files.bytes, hashes: files.hashes)
    let languageFolder = root.appendingPathComponent(code)
    try JSONEncoder().encode(saved).write(to: languageFolder.appendingPathComponent("state.json"), options: .atomic)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: languageFolder.path)) ?? []
    where name != saved.folder && name != "state.json" {
      try? FileManager.default.removeItem(at: languageFolder.appendingPathComponent(name))
    }
  }

  func remove(_ code: String) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(code))
  }

  /// The bundles that answer for `code`, one per source that has files, in the sources' order.
  func bundles(of code: String, sources: [String]) -> [Bundle] {
    guard let saved = state(of: code) else { return [] }
    let folder = root.appendingPathComponent(code).appendingPathComponent(saved.folder)
    return sources.compactMap { source in
      let path = folder.appendingPathComponent(source)
      guard FileManager.default.fileExists(atPath: path.appendingPathComponent("\(code).lproj").path) else {
        return nil
      }
      return Bundle(url: path)
    }
  }
}

/// Where the files come from: v57/Localizations on GitHub at the commit the release was built with
/// (`V57LocalizationsCommit` in Info.plist), its manifest checked against the SHA-256 the release recorded
/// (`V57LocalizationsManifest`) and every file against the manifest. A Release build without a commit downloads
/// nothing (`configured` is nil); a Debug build without one reads `main`, or `V57_LOCALIZATIONS_URL` (a folder or a
/// server, for testing), which a Release build ignores.
struct PackRemote: Sendable {
  let base: URL
  /// manifest.json's SHA-256 (hex), when the release recorded it.
  var manifestSHA256: String? = nil

  static let gitHub = "https://raw.githubusercontent.com/v57/Localizations/"

  static var `default`: PackRemote? {
    #if DEBUG
      let debug = true
    #else
      let debug = false
    #endif
    return configured(
      info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment, debug: debug)
  }

  /// The remote a build with this Info.plist and environment reads, or nil when it downloads nothing.
  static func configured(info: [String: Any], environment: [String: String], debug: Bool) -> PackRemote? {
    if debug, let custom = environment["V57_LOCALIZATIONS_URL"].flatMap({ value -> URL? in
      value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : URL(string: value)
    }) {
      return PackRemote(base: custom)
    }
    if let commit = info["V57LocalizationsCommit"] as? String {
      guard isCommit(commit) else { return nil }
      return PackRemote(
        base: URL(string: gitHub + commit + "/")!,
        manifestSHA256: (info["V57LocalizationsManifest"] as? String)?.lowercased())
    }
    return debug ? PackRemote(base: URL(string: gitHub + "main/")!) : nil
  }

  /// A full commit hash: 40 lowercase hex digits.
  static func isCommit(_ text: String) -> Bool {
    text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  /// SHA-256 as lowercase hex.
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func data(at path: String) async throws -> Data {
    let url = base.appendingPathComponent(path)
    if url.isFileURL { return try Data(contentsOf: url) }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw LanguagePackError.server(status) }
    return data
  }

  func manifest() async throws -> Manifest {
    let data = try await data(at: "manifest.json")
    if let manifestSHA256, Self.sha256(data) != manifestSHA256 { throw LanguagePackError.badManifest }
    guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1 else {
      throw LanguagePackError.badManifest
    }
    return manifest
  }
}
