import Foundation
import Observation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if !canImport(Darwin)
  import SwiftUI
#endif

/// The app's translations beyond the ones it ships: downloaded on request from v57/Localizations and answered
/// behind the app's own strings, so `Text("Open")`, `String(localized:)` and menus show them like bundled ones.
///
/// An app names its sources (its own strings, then its kits') and starts the packs first thing, before any text
/// resolves; ComponentKit's Settings ▸ Languages pane and `kitLanguages()` do the rest.
///
/// ```swift
/// init() { LanguagePacks.start(sources: ["Markdown", "ComponentKit", "VaultUI"]) }
/// ```
///
/// The app's language is the one the system picked for it (on Apple platforms from `CFBundleLocalizations`, which a
/// release lists every translation in; elsewhere SwiftUI's `AppLanguage`). Only that language's pack is used. A
/// release's Info.plist names the languages it can download with their size (`V57Languages`, code → bytes), so the
/// list needs no request; otherwise it fills once `checkForUpdates()` has read the manifest. Nothing is downloaded
/// or checked without being asked.
@MainActor @Observable
public final class LanguagePacks {
  public static let shared = LanguagePacks(store: PackStore(root: PackStore.defaultRoot), remote: .default, hooks: true)

  /// One of the app's languages.
  public struct Language: Identifiable, Hashable, Sendable {
    public var id: String { code }
    /// "de", "pt-BR", "zh-Hans".
    public let code: String
    /// Its name in the app's language ("German").
    public let name: String
    /// Its name in itself ("Deutsch").
    public let ownName: String
    public let state: State
    /// Whether the app runs in it.
    public let isActive: Bool
  }

  public enum State: Hashable, Sendable {
    /// In the app itself.
    case included
    /// Can be downloaded; its size when known.
    case available(bytes: Int?)
    case downloading
    /// Downloaded; `updateAvailable` once a check found newer files.
    case downloaded(bytes: Int, updateAvailable: Bool)
  }

  /// The app's sources, best first.
  public private(set) var sources: [String] = []
  /// The language the app runs in ("de").
  public private(set) var language = "en"
  /// Every language the app has, can download or has downloaded: the app's language first, then the included ones,
  /// then by name.
  public private(set) var languages: [Language] = []
  /// Changes whenever the app's strings change (a pack came, was updated or went): views rebuilt on it show them.
  public private(set) var revision = 0
  /// When the manifest was last read, in this launch.
  public private(set) var checked: Date?

  private var manifest: Manifest?
  private var downloading: Set<String> = []
  private var offered: Set<String>
  private let store: PackStore
  /// Where downloads come from; nil in a Release build that has no v57/Localizations commit (no downloads).
  private let remote: PackRemote?
  private let hooks: Bool

  init(store: PackStore, remote: PackRemote?, hooks: Bool) {
    self.store = store
    self.remote = remote
    self.hooks = hooks
    offered = Set(UserDefaults.standard.stringArray(forKey: Self.offeredKey) ?? [])
  }

  /// Names the app's sources and uses the downloaded pack of its language. Call before any text resolves (the App's
  /// `init`).
  public static func start(sources: [String]) {
    shared.start(sources: sources)
  }

  func start(sources: [String]) {
    self.sources = sources
    language = Self.appLanguage(candidates: Self.included + Array(Self.downloadable.keys) + store.downloaded())
    if store.state(of: language) != nil { activate() }
    refresh()
  }

  /// The app's language when it can be downloaded and hasn't been yet, and the app hasn't offered it before: ask once
  /// whether to download it (then `dismissOffer()`).
  public var offer: Language? {
    guard !offered.contains(language), let current = languages.first(where: { $0.code == language }),
      case .available = current.state
    else { return nil }
    return current
  }

  /// Remembers that the app offered its language, whatever the answer.
  public func dismissOffer() {
    offered.insert(language)
    UserDefaults.standard.set(offered.sorted(), forKey: Self.offeredKey)
  }

  /// Reads the manifest: the languages the app's sources have there and whether downloaded ones have newer files.
  @discardableResult
  public func checkForUpdates() async throws -> Bool {
    guard let remote else { throw LanguagePackError.unavailable }
    let manifest = try await remote.manifest()
    self.manifest = manifest
    checked = Date()
    refresh()
    return languages.contains {
      if case .downloaded(_, true) = $0.state { return true } else { return false }
    }
  }

  /// Downloads `code`'s files for the app's sources (again, for an update), checks every line and uses them at once
  /// when the app runs in that language. Elsewhere than on Apple platforms the language's ICU formats come with it
  /// when the app's build lacks them.
  public func download(_ code: String) async throws {
    guard let remote else { throw LanguagePackError.unavailable }
    guard Manifest.isLanguageCode(code) else { throw LanguagePackError.noTranslations(code) }
    guard !downloading.contains(code) else { return }
    downloading.insert(code)
    refresh()
    defer {
      downloading.remove(code)
      refresh()
    }
    let manifest = try await remote.manifest()
    self.manifest = manifest
    checked = Date()
    let files = manifest.files(of: code, in: sources)
    guard !files.isEmpty else { throw LanguagePackError.noTranslations(code) }
    let folder = try await Self.fetch(files, language: code, remote: remote, store: store)
    try store.install(folder, language: code, files: files)
    #if !canImport(Darwin)
      if code == language, ICULanguagePack.missingLanguage == AppLanguage.languageCode {
        try? await ICULanguagePack.download(AppLanguage.languageCode)
      }
    #endif
    if code == language { activate() }
  }

  /// Deletes a downloaded language; the app's strings go back to English when it runs in it.
  public func remove(_ code: String) {
    store.remove(code)
    if code == language { activate() }
    refresh()
  }

  // MARK: - Internals

  private static let offeredKey = "PlatformLanguages.offered"

  /// The languages the app's bundle holds (the stub `.lproj` of a downloadable one doesn't count).
  static var included: [String] {
    let downloadable = Self.downloadable
    let own = Bundle.main.localizations.filter { $0 != "Base" && downloadable[$0] == nil }
    return own.isEmpty ? [developmentLanguage] : own
  }

  /// The app's development language. Read from Info.plist: swift-corelibs-foundation's
  /// `Bundle.developmentLocalization` traps on Windows (Markdown 0.1.0 died at launch).
  static var developmentLanguage: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String ?? "en"
  }

  /// The languages a release can download, with their size (Info.plist's `V57Languages`).
  static var downloadable: [String: Int] {
    var info = Bundle.main.object(forInfoDictionaryKey: "V57Languages") as? [String: Any]
    #if DEBUG
      // A debug build lists none: `-V57Languages '{de = 1200;}'` stands in for a release's list.
      info = info ?? UserDefaults.standard.dictionary(forKey: "V57Languages")
    #endif
    guard let table = info else { return [:] }
    // A launch argument's numbers come as strings.
    return table.compactMapValues { ($0 as? NSNumber)?.intValue ?? ($0 as? String).flatMap { Int($0) } }
  }

  /// The language the system picked for the app, among `candidates`.
  static func appLanguage(candidates: [String]) -> String {
    let development = developmentLanguage
    #if canImport(Darwin)
      // A release lists every language in CFBundleLocalizations, so the system's pick (per-app language included)
      // is the answer; a build that lists none falls back to the user's languages.
      if let picked = Bundle.main.preferredLocalizations.first, picked != development { return picked }
      return best(of: candidates, for: Locale.preferredLanguages) ?? development
    #else
      return best(of: candidates, for: [AppLanguage.identifier]) ?? development
    #endif
  }

  /// The first of `preferences` ("de_AT", "zh-Hans-CN") that one of `candidates` serves, exactly or by a shorter
  /// form ("de", "zh-Hans").
  nonisolated static func best(of candidates: [String], for preferences: [String]) -> String? {
    let known = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    for preference in preferences {
      var parts = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
      while !parts.isEmpty {
        if let match = known[parts.joined(separator: "-").lowercased()] { return match }
        parts.removeLast()
      }
    }
    return nil
  }

  private func activate() {
    let bundles = store.bundles(of: language, sources: sources)
    if hooks { PackHook.use(bundles) }
    revision += 1
  }

  private func refresh() {
    let included = Set(Self.included)
    // A build that can't download (a Release build without a pinned commit) offers nothing.
    let downloadable = remote == nil ? [:] : Self.downloadable
    var codes = included.union(downloadable.keys).union(store.downloaded())
    if let manifest { codes.formUnion(manifest.languages(in: sources)) }
    codes.remove("Base")
    let names = Locale(identifier: language)
    languages = codes.map { code in
      let state: State
      if downloading.contains(code) {
        state = .downloading
      } else if let saved = store.state(of: code) {
        let newer = manifest.map { manifest in
          let current = manifest.files(of: code, in: sources)
          return !current.isEmpty && current.hashes != saved.hashes
        }
        state = .downloaded(bytes: saved.bytes, updateAvailable: newer ?? false)
      } else if included.contains(code) {
        state = .included
      } else {
        state = .available(bytes: manifest?.files(of: code, in: sources).bytes ?? downloadable[code])
      }
      let own = Locale(identifier: code)
      let ownName = own.localizedString(forIdentifier: code).map { $0.capitalized(with: own) } ?? code
      let name = names.localizedString(forIdentifier: code).map { $0.capitalized(with: names) } ?? ownName
      return Language(code: code, name: name, ownName: ownName, state: state, isActive: code == language)
    }
    .sorted { first, second in
      if first.isActive != second.isActive { return first.isActive }
      let firstIncluded = first.state == .included, secondIncluded = second.state == .included
      if firstIncluded != secondIncluded { return firstIncluded }
      return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
    }
  }

  /// Downloads `files`, checks each against the manifest's SHA-256 and every line against its key, into a new folder
  /// of the store.
  nonisolated private static func fetch(_ files: [PackFile], language: String, remote: PackRemote, store: PackStore)
    async throws -> URL
  {
    let folder = try store.newFolder(for: language)
    do {
      for file in files {
        // The manifest dropped any other names already; checked again because they become paths.
        guard Manifest.isSourceName(file.source), Manifest.isLanguageCode(language), Manifest.isFileName(file.name)
        else { throw LanguagePackError.badManifest }
        let path = "\(file.source)/\(language).lproj/\(file.name)"
        let data = try await remote.data(at: path)
        guard PackRemote.sha256(data) == file.sha256.lowercased() else { throw LanguagePackError.badFile(path) }
        let checked: Data
        if file.name.hasSuffix(".stringsdict") {
          let table = try FormatCheck.checkedStringsdict(data).table
          checked = try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
        } else {
          let table = try FormatCheck.checkedStrings(data).table
          checked = try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
        }
        let target = folder.appendingPathComponent("\(file.source)/\(language).lproj/\(file.name)")
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checked.write(to: target, options: .atomic)
      }
      return folder
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
}

public enum LanguagePackError: LocalizedError, Equatable {
  case noTranslations(String)
  case server(Int)
  case badManifest
  /// A file isn't the one the manifest describes.
  case badFile(String)
  /// This build downloads no translations (a Release build without a v57/Localizations commit).
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .noTranslations(let code):
      let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
      return "There are no \(name) translations to download yet."
    case .server(let status):
      return "The download failed (\(status == 0 ? "no response" : "HTTP \(status)"))."
    case .badManifest:
      return "The list of translations couldn't be read."
    case .badFile(let path):
      return "\(path) isn't the file the list of translations describes."
    case .unavailable:
      return "This build of the app can't download translations."
    }
  }
}
