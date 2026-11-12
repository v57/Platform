import CryptoKit
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

    /// manifest.json for the files in the folder, with their real sizes and SHA-256; `extra` adds entries as they are
    /// (source → language → name → file).
    func manifest(extra: [String: [String: [String: [String: Any]]]] = [:]) throws {
      var sources: [String: [String: [String: [String: Any]]]] = [:]
      for source in try FileManager.default.contentsOfDirectory(atPath: root.path) where !source.hasSuffix(".json") {
        for lproj in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(source).path) {
          let language = String(lproj.dropLast(".lproj".count))
          for name in try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("\(source)/\(lproj)").path)
          {
            let data = try Data(contentsOf: root.appendingPathComponent("\(source)/\(lproj)/\(name)"))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            sources[source, default: [:]][language, default: [:]][name] = ["bytes": data.count, "sha256": hash]
          }
        }
      }
      for (source, languages) in extra {
        for (language, files) in languages {
          for (name, file) in files { sources[source, default: [:]][language, default: [:]][name] = file }
        }
      }
      let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sources": sources])
      try data.write(to: root.appendingPathComponent("manifest.json"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
  }

  func packs(_ repository: Repository, manifestSHA256: String? = nil) -> (LanguagePacks, PackStore) {
    let store = PackStore(root: repository.root.appendingPathExtension("store"))
    let remote = PackRemote(base: repository.root, manifestSHA256: manifestSHA256)
    let packs = LanguagePacks(store: store, remote: remote, hooks: false)
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
    try repository.write("Kit", "de", "Localizable.strings", "\"Open\" = \"Kit-Öffnen\";\n\"Cancel\" = \"Abbruch\";\n")
    try repository.manifest()
    #expect(try await packs.checkForUpdates())
    try await packs.download("de")
    #expect(try #require(store.state(of: "de")).folder != before)
    #expect(try await packs.checkForUpdates() == false)

    packs.remove("de")
    #expect(store.downloaded().isEmpty)
    let updated = try ["App", "Kit"].reduce(0) {
      $0 + (try Data(contentsOf: repository.root.appendingPathComponent("\($1)/de.lproj/Localizable.strings")).count)
    }
    #expect(packs.languages.first { $0.code == "de" }?.state == .available(bytes: updated))
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

  /// Language codes and file names become paths: the manifest can't name one outside the language's folder
  /// (Ideas/Security/supply-chain.md M5).
  @Test func aManifestCantNamePaths() async throws {
    let repository = Repository()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Öffnen\";\n")
    let plist = "\"Open\" = \"Pwned\";\n"
    try repository.write("App", "de", "x.strings", plist)
    let hash = SHA256.hash(data: Data(plist.utf8)).map { String(format: "%02x", $0) }.joined()
    let file: [String: Any] = ["bytes": plist.utf8.count, "sha256": hash]
    try repository.manifest(extra: [
      "App": [
        "de": ["../../../../escaped.strings": file, "Info.plist": file],
        "../../../../evil": ["Localizable.strings": file],
      ]
    ])
    let (packs, store) = packs(repository)
    defer { try? FileManager.default.removeItem(at: store.root) }
    try await packs.checkForUpdates()
    #expect(packs.languages.map(\.code).allSatisfy { !$0.contains("/") && !$0.contains(".") })
    await #expect(throws: LanguagePackError.noTranslations("../../../../evil")) {
      try await packs.download("../../../../evil")
    }
    try await packs.download("de")
    let state = try #require(store.state(of: "de"))
    #expect(state.hashes.keys.sorted() == ["App/Localizable.strings", "App/x.strings"])
    // Nothing landed beside the store, or anywhere but de's folder.
    let written = try FileManager.default.subpathsOfDirectory(atPath: store.root.path)
    #expect(written.allSatisfy { $0 == "de" || $0.hasPrefix("de/") })
    #expect(!FileManager.default.fileExists(atPath: store.root.deletingLastPathComponent().appendingPathComponent("escaped.strings").path))
  }

  /// A file that isn't the one the manifest describes is refused, and nothing is installed.
  @Test func aFileThatIsntTheManifestsIsRefused() async throws {
    let repository = Repository()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Öffnen\";\n")
    try repository.manifest()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Phishing\";\n")
    let (packs, store) = packs(repository)
    defer { try? FileManager.default.removeItem(at: store.root) }
    await #expect(throws: LanguagePackError.badFile("App/de.lproj/Localizable.strings")) { try await packs.download("de") }
    #expect(store.downloaded().isEmpty)
  }

  /// A release names the manifest it was built with; another one at its commit is refused.
  @Test func aPinnedManifestMustMatch() async throws {
    let repository = Repository()
    try repository.write("App", "de", "Localizable.strings", "\"Open\" = \"Öffnen\";\n")
    try repository.manifest()
    let manifest = try Data(contentsOf: repository.root.appendingPathComponent("manifest.json"))
    let pinned = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    let (good, goodStore) = packs(repository, manifestSHA256: pinned)
    defer { try? FileManager.default.removeItem(at: goodStore.root) }
    try await good.download("de")
    let (bad, _) = packs(repository, manifestSHA256: String(repeating: "0", count: 64))
    await #expect(throws: LanguagePackError.badManifest) { try await bad.checkForUpdates() }
  }

  /// Release builds download from the commit Info.plist names, or not at all; only Debug builds take main or
  /// V57_LOCALIZATIONS_URL.
  @Test func whereDownloadsComeFrom() throws {
    let commit = "1b125e0b765562e29b33b9e770fb68be5139258b"
    let info: [String: Any] = ["V57LocalizationsCommit": commit, "V57LocalizationsManifest": "ABC"]
    let override = ["V57_LOCALIZATIONS_URL": "http://127.0.0.1:9/"]
    let release = try #require(PackRemote.configured(info: info, environment: override, debug: false))
    #expect(release.base.absoluteString == "https://raw.githubusercontent.com/v57/Localizations/\(commit)/")
    #expect(release.manifestSHA256 == "abc")
    #expect(PackRemote.configured(info: [:], environment: [:], debug: false) == nil)
    #expect(PackRemote.configured(info: [:], environment: override, debug: false) == nil)
    #expect(PackRemote.configured(info: ["V57LocalizationsCommit": "main"], environment: [:], debug: false) == nil)
    #expect(PackRemote.configured(info: ["V57LocalizationsCommit": "main"], environment: [:], debug: true) == nil)
    #expect(PackRemote.configured(info: [:], environment: override, debug: true)?.base.absoluteString == "http://127.0.0.1:9/")
    #expect(
      PackRemote.configured(info: [:], environment: [:], debug: true)?.base.absoluteString
        == "https://raw.githubusercontent.com/v57/Localizations/main/")
    #expect(PackRemote.configured(info: info, environment: [:], debug: true)?.base == release.base)
  }

  @Test func aBuildThatCantDownloadOffersNothing() async throws {
    let store = PackStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)"))
    let packs = LanguagePacks(store: store, remote: nil, hooks: false)
    packs.start(sources: ["App"])
    #expect(packs.offer == nil)
    #expect(!packs.languages.contains { if case .available = $0.state { true } else { false } })
    await #expect(throws: LanguagePackError.unavailable) { try await packs.checkForUpdates() }
    await #expect(throws: LanguagePackError.unavailable) { try await packs.download("de") }
  }

  @Test func namesThatAreLanguagesAndFiles() {
    for code in ["de", "pt-BR", "zh-Hans", "sr-Latn-RS", "fil"] { #expect(Manifest.isLanguageCode(code), "\(code)") }
    for code in ["", "DE", "d", "deut", "de-", "de/x", "../de", "de-B", "de-123456789", ".."] {
      #expect(!Manifest.isLanguageCode(code), "\(code)")
    }
    for name in ["Localizable.strings", "Localizable.stringsdict", "InfoPlist.strings", "a_b+c-d.strings"] {
      #expect(Manifest.isFileName(name), "\(name)")
    }
    for name in [".strings", "../x.strings", "x/y.strings", "Info.plist", "x.strings.plist", "x y.strings"] {
      #expect(!Manifest.isFileName(name), "\(name)")
    }
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
      // SwiftUI's Text asks for an attributed string, which parses Markdown.
      let attributed = Bundle.main.perform(
        NSSelectorFromString("localizedAttributedStringForKey:value:table:"), with: "Pack Missing", with: nil)
      #expect((attributed?.takeUnretainedValue() as? NSAttributedString)?.string == "Pack Missing")
      PackHook.use([])
      #expect(String(localized: "Pack Hello \(name)") == "Pack Hello Ana")
    }

    /// A stringsdict whose keys each have `forms` (plural category → text): what Scripts/build compiles.
    static func stringsdict(_ entries: [String: [String: String]]) throws -> String {
      let table = entries.mapValues { forms -> [String: Any] in
        var value: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]
        value.merge(forms) { _, new in new }
        return ["NSStringLocalizedFormatKey": "%#@value@", "value": value]
      }
      let data = try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
      return String(decoding: data, as: UTF8.self)
    }

    /// English plural variants answer after the app's own tables and after a pack that lacks the key, never before a
    /// pack that has it; without them a count reads as its key.
    @Test func countsReadInEnglishPluralForms() throws {
      let repository = Repository()
      try repository.write(
        "English", "en", "Localizable.stringsdict",
        try Self.stringsdict([
          "English %lld servers": ["one": "English %lld server", "other": "English %lld servers"],
          "English %lld files": ["one": "English %lld file", "other": "English %lld files"],
        ]))
      try repository.write("Pack", "de", "Localizable.strings", "\"English Hello\" = \"Hallo\";\n")
      try repository.write(
        "Pack", "de", "Localizable.stringsdict",
        try Self.stringsdict(["English %lld files": ["one": "%lld Datei", "other": "%lld Dateien"]]))
      let english = try #require(Bundle(url: repository.root.appendingPathComponent("English")))
      let pack = try #require(Bundle(url: repository.root.appendingPathComponent("Pack")))
      defer {
        PackHook.use([])
        PackHook.useEnglish(nil)
      }

      #expect(String(localized: "English \(1) servers") == "English 1 servers")
      PackHook.useEnglish(english)
      #expect(String(localized: "English \(1) servers") == "English 1 server")
      #expect(String(localized: "English \(3) servers") == "English 3 servers")
      #expect(String(localized: "English \(0) servers") == "English 0 servers")
      #expect(String(AttributedString(localized: "English \(1) servers").characters) == "English 1 server")
      #expect(String.localizedStringWithFormat(NSLocalizedString("English %lld servers", comment: ""), 1) == "English 1 server")
      // Keys that aren't counts stay the code's text, every time they're asked (a window's title once came back as
      // the pack sentinel the second time).
      for _ in 0..<2 {
        #expect(String(localized: "English Hello") == "English Hello")
        #expect(Bundle.main.localizedString(forKey: "English Title", value: nil, table: nil) == "English Title")
        #expect(Bundle.main.localizedString(forKey: "English Title", value: "Shown", table: nil) == "Shown")
        let attributed = Bundle.main.perform(
          NSSelectorFromString("localizedAttributedStringForKey:value:table:"), with: "English Title", with: nil)
        #expect((attributed?.takeUnretainedValue() as? NSAttributedString)?.string == "English Title")
      }

      // A pack answers first; a key it lacks falls back to English, pluralized.
      PackHook.use([pack])
      #expect(String(localized: "English Hello") == "Hallo")
      #expect(String(localized: "English \(1) files") == "1 Datei")
      #expect(String(localized: "English \(4) files") == "4 Dateien")
      #expect(String(localized: "English \(1) servers") == "English 1 server")
      #expect(String(localized: "English \(2) servers") == "English 2 servers")

      PackHook.use([])
      PackHook.useEnglish(nil)
      #expect(String(localized: "English \(1) servers") == "English 1 servers")
    }

    /// A Russian pack keeps its own plural forms (one, few, many) with English behind it.
    @Test func aPackKeepsItsLanguagesPluralForms() throws {
      let repository = Repository()
      try repository.write(
        "English", "en", "Localizable.stringsdict",
        try Self.stringsdict(["Russian %lld servers": ["one": "%lld server", "other": "%lld servers"]]))
      try repository.write(
        "Pack", "ru", "Localizable.stringsdict",
        try Self.stringsdict([
          "Russian %lld servers": [
            "one": "%lld сервер", "few": "%lld сервера", "many": "%lld серверов", "other": "%lld сервера",
          ]
        ]))
      let english = try #require(Bundle(url: repository.root.appendingPathComponent("English")))
      let pack = try #require(Bundle(url: repository.root.appendingPathComponent("Pack")))
      PackHook.useEnglish(english)
      PackHook.use([pack])
      defer {
        PackHook.use([])
        PackHook.useEnglish(nil)
      }
      let russian = Locale(identifier: "ru")
      let format = NSLocalizedString("Russian %lld servers", comment: "")
      #expect(String(format: format, locale: russian, 1) == "1 сервер")
      #expect(String(format: format, locale: russian, 3) == "3 сервера")
      #expect(String(format: format, locale: russian, 5) == "5 серверов")
      #expect(String(format: format, locale: russian, 21) == "21 сервер")
    }

    /// The table this library ships answers the apps' real count keys.
    @Test func theShippedEnglishTableAnswersTheAppsKeys() throws {
      let english = try #require(EnglishPlurals.bundle)
      PackHook.useEnglish(english)
      defer { PackHook.useEnglish(nil) }
      #expect(String(localized: "\(1) devices") == "1 device")
      #expect(String(localized: "\(2) devices") == "2 devices")
      #expect(String(localized: "\(1) logins") == "1 login")
      #expect(String(localized: "\(1) items") == "1 item")
    }
  #endif
}
