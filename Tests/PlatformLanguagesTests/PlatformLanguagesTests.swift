import Foundation
import Testing

@testable import PlatformLanguages

@Suite struct FormatCheckTests {
  @Test func plainLinesKeepTheKeysArguments() {
    #expect(FormatCheck.fits("Hallo %@", key: "Hello %@"))
    #expect(FormatCheck.fits("%lld Dateien in %@", key: "%lld files in %@"))
    // Reordered by position, or an argument left out.
    #expect(FormatCheck.fits("In %2$@: %1$lld Dateien", key: "%lld files in %@"))
    #expect(FormatCheck.fits("Dateien in %2$@", key: "%lld files in %@"))
    #expect(FormatCheck.fits("100 %% fertig", key: "100%% done"))
    // The wrong kind, in order or by position, an argument the key hasn't, %n.
    #expect(!FormatCheck.fits("%@ Dateien in %lld", key: "%lld files in %@"))
    #expect(!FormatCheck.fits("%1$@", key: "%lld files in %@"))
    #expect(!FormatCheck.fits("Hallo %@ %@", key: "Hello %@"))
    #expect(!FormatCheck.fits("Hallo %d", key: "Hello %lld"))
    #expect(!FormatCheck.fits("Hallo %s", key: "Hello %@"))
    #expect(!FormatCheck.fits("Hallo %@%n", key: "Hello %@"))
    #expect(FormatCheck.fits("Pi: %.2f", key: "Pi is %.3lf"))
  }

  @Test func keysWithoutArgumentsAllowWhatCantCrash() {
    #expect(FormatCheck.fits("100 % des fichiers", key: "100% of files"))
    #expect(FormatCheck.fits("Fertig", key: "Done"))
    #expect(!FormatCheck.fits("Fertig %@", key: "Done"))
    #expect(!FormatCheck.fits("Fertig %s", key: "Done"))
  }

  @Test func pluralEntriesUseTheKeysKinds() {
    func entry(_ format: String, _ forms: [String: String]) -> [String: Any] {
      var variable: [String: Any] = [
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
      ]
      for (form, value) in forms { variable[form] = value }
      return ["NSStringLocalizedFormatKey": format, "value": variable]
    }
    // As xcstringstool writes them: the number dropped in "one", positions when the plural isn't first.
    #expect(FormatCheck.fits(pluralEntry: entry("%#@value@", ["one": "Eine Datei in %@", "other": "%lld Dateien in %@"]), key: "%lld files in %@"))
    #expect(FormatCheck.fits(pluralEntry: entry("%2$#@value@", ["one": "%1$@ hat eine Datei", "other": "%1$@ hat %2$lld Dateien"]), key: "%@ has %lld files"))
    #expect(!FormatCheck.fits(pluralEntry: entry("%#@value@", ["one": "%@ Datei", "other": "%lld Dateien"]), key: "%lld files"))
    #expect(!FormatCheck.fits(pluralEntry: entry("%#@value@", ["other": "%3$lld Dateien"]), key: "%lld files"))
    #expect(!FormatCheck.fits(pluralEntry: ["value": [:] as [String: Any]], key: "%lld files"))
  }

  @Test func tablesLoseOnlyTheLinesThatDontFit() throws {
    let text = "\"Hello %@\" = \"Hallo %@\";\n\"Files %lld\" = \"Dateien %@\";\n\"Done\" = \"Fertig\";\n"
    let (table, dropped) = try FormatCheck.checkedStrings(Data(text.utf8))
    #expect(table == ["Hello %@": "Hallo %@", "Done": "Fertig"])
    #expect(dropped == ["Files %lld"])
  }
}

@MainActor @Suite(.serialized) struct LanguagePacksTests {
  /// A folder laid out like v57/Localizations, with `manifest.json`.
  final class Repository {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("localizations-\(UUID().uuidString)")

    func write(_ source: String, _ language: String, _ name: String, _ text: String) throws {
      let folder = root.appendingPathComponent("\(source)/\(language).lproj")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func manifest(hash: String = "1") throws {
      var sources: [String: [String: [String: [String: Any]]]] = [:]
      for source in try FileManager.default.contentsOfDirectory(atPath: root.path) where !source.hasSuffix(".json") {
        for lproj in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(source).path) {
          let language = String(lproj.dropLast(".lproj".count))
          for name in try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("\(source)/\(lproj)").path)
          {
            let size = try Data(contentsOf: root.appendingPathComponent("\(source)/\(lproj)/\(name)")).count
            sources[source, default: [:]][language, default: [:]][name] = ["bytes": size, "sha256": "\(name)-\(hash)"]
          }
        }
      }
      let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sources": sources])
      try data.write(to: root.appendingPathComponent("manifest.json"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
  }

  func packs(_ repository: Repository) -> (LanguagePacks, PackStore) {
    let store = PackStore(root: repository.root.appendingPathExtension("store"))
    let packs = LanguagePacks(store: store, remote: PackRemote(base: repository.root), hooks: false)
    packs.start(sources: ["App", "Kit"])
    return (packs, store)
  }

  @Test func downloadsChecksUpdatesAndRemovesALanguage() async throws {
    let repository = Repository()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Öffnen\";\n\"Files %lld\" = \"Dateien %@\";\n")
    try repository.write("Kit", "de", "Localizable.strings", "\"Open\" = \"Kit-Öffnen\";\n\"Cancel\" = \"Abbrechen\";\n")
    try repository.write("Other", "fr", "Localizable.strings", "\"Open\" = \"Ouvrir\";\n")
    try repository.manifest()
    let (packs, store) = packs(repository)
    defer { try? FileManager.default.removeItem(at: store.root) }
    let bytes = try ["App", "Kit"].reduce(0) {
      $0 + (try Data(contentsOf: repository.root.appendingPathComponent("\($1)/de.lproj/Localizable.strings")).count)
    }

    // Nothing is listed beyond the app's own languages until the manifest is read; a source the app doesn't use
    // doesn't count.
    #expect(!packs.languages.contains { $0.code == "de" })
    try await packs.checkForUpdates()
    #expect(packs.languages.first { $0.code == "de" }?.state == .available(bytes: bytes))
    #expect(!packs.languages.contains { $0.code == "fr" })

    try await packs.download("de")
    guard case .downloaded(_, false) = packs.languages.first(where: { $0.code == "de" })?.state else {
      Issue.record("not downloaded")
      return
    }
    // The app's source first, then the kit's; the line whose argument doesn't fit was dropped.
    let bundles = store.bundles(of: "de", sources: ["App", "Kit"])
    func lookUp(_ key: String) -> String {
      for bundle in bundles {
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        if value != "\u{0}" { return value }
      }
      return key
    }
    #expect(lookUp("Open") == "Öffnen")
    #expect(lookUp("Cancel") == "Abbrechen")
    #expect(lookUp("Files %lld") == "Files %lld")

    // Newer files on the server make an update; downloading again takes them, in a new folder.
    let before = try #require(store.state(of: "de")).folder
    try repository.manifest(hash: "2")
    #expect(try await packs.checkForUpdates())
    try await packs.download("de")
    #expect(try #require(store.state(of: "de")).folder != before)
    #expect(try await packs.checkForUpdates() == false)

    packs.remove("de")
    #expect(store.downloaded().isEmpty)
    #expect(packs.languages.first { $0.code == "de" }?.state == .available(bytes: bytes))
  }

  @Test func aLanguageNobodyTranslatedSaysSo() async throws {
    let repository = Repository()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Öffnen\";\n")
    try repository.manifest()
    let (packs, store) = packs(repository)
    defer { try? FileManager.default.removeItem(at: store.root) }
    await #expect(throws: LanguagePackError.noTranslations("ja")) { try await packs.download("ja") }
    #expect(store.downloaded().isEmpty)
  }

  @Test func thePreferredLanguageMatchesByShorterForms() {
    #expect(LanguagePacks.best(of: ["en", "de", "zh-Hans"], for: ["de_AT"]) == "de")
    #expect(LanguagePacks.best(of: ["en", "de", "zh-Hans"], for: ["zh-Hans-CN"]) == "zh-Hans")
    #expect(LanguagePacks.best(of: ["en", "pt-BR"], for: ["pt-BR"]) == "pt-BR")
    #expect(LanguagePacks.best(of: ["en", "pt-BR"], for: ["pt-PT", "en-GB"]) == "en")
    #expect(LanguagePacks.best(of: ["en", "de"], for: ["fr"]) == nil)
  }

  #if canImport(ObjectiveC)
    /// The main bundle answers from the pack for every Foundation lookup, and from itself again without one.
    @Test func theMainBundleAnswersFromThePack() throws {
      let repository = Repository()
      try repository.write("App", "de", "Localizable.strings", "\"Pack Hello %@\" = \"Hallo %@\";\n")
      try repository.write(
        "App", "de", "Localizable.stringsdict",
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Pack %lld files</key><dict>
        <key>NSStringLocalizedFormatKey</key><string>%#@value@</string>
        <key>value</key><dict><key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key><string>lld</string>
        <key>one</key><string>%lld Datei</string><key>other</key><string>%lld Dateien</string></dict></dict></dict></plist>
        """)
      let pack = try #require(Bundle(url: repository.root.appendingPathComponent("App")))
      PackHook.use([pack])
      defer { PackHook.use([]) }
      let name = "Ana"
      #expect(String(localized: "Pack Hello \(name)") == "Hallo Ana")
      #expect(String(localized: "Pack \(3) files") == "3 Dateien")
      #expect(String(localized: "Pack \(1) files") == "1 Datei")
      #expect(NSLocalizedString("Pack Hello %@", comment: "") == "Hallo %@")
      #expect(String(AttributedString(localized: "Pack Hello \(name)").characters) == "Hallo Ana")
      #expect(String(localized: "Pack Missing") == "Pack Missing")
      PackHook.use([])
      #expect(String(localized: "Pack Hello \(name)") == "Pack Hello Ana")
    }
  #endif
}
