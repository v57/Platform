import Foundation

#if canImport(ObjectiveC)
  import ObjectiveC
#endif
#if !canImport(Darwin)
  import SwiftUI
#endif

/// Puts a language pack's bundles in front of the main bundle's own tables, and English plural variants behind them.
///
/// On Apple platforms the main bundle becomes a subclass whose string lookups ask the pack bundles first, with the
/// same arguments, then the bundle itself. Apple's SwiftUI, AppKit, UIKit and Foundation look strings up through
/// several NSBundle methods, public and private (checked on macOS 27 and iOS 27.2, Demos/LanguagePacks):
///
/// - `localizedAttributedStringForKey:value:table:`: SwiftUI's `Text`, `Button`, `Label`, titles, menus;
/// - `_localizedStringForKey:value:table:localizations:`: `String(localized:)`, `LocalizedStringResource`;
/// - `_localizedStringNoCacheNoMarkdownParsingForKey:…formatSpecifierConfiguration:`: `Text(LocalizedStringResource)`,
///   `AttributedString(localized:)`;
/// - `localizedStringForKey:value:table:`: `NSLocalizedString`, `Bundle.localizedString`.
///
/// Each is added only when NSBundle still has it, so an OS that renames a private one shows English there, never
/// crashes. Elsewhere v57/SwiftUI asks the pack bundles itself (`_AppLocale._setPackBundles`).
enum PackHook {
  /// The language pack's bundles: asked before the app's own tables.
  @MainActor static func use(_ bundles: [Bundle]) {
    #if canImport(ObjectiveC)
      Packs.set(bundles)
      if !bundles.isEmpty { install() }
    #else
      packs = bundles
      _AppLocale._setPackBundles(packs + (english.map { [$0] } ?? []))
    #endif
  }

  /// English plural variants (`EnglishPlurals`): asked after the pack and the app's own tables, so a count reads
  /// "1 server" in English and in a language whose translation lacks the key; nil stops asking.
  @MainActor static func useEnglish(_ bundle: Bundle?) {
    #if canImport(ObjectiveC)
      Packs.setEnglish(bundle)
      if bundle != nil { install() }
    #else
      // v57/SwiftUI asks the packs before the bundle's own `.lproj`, which off Apple platforms holds no translations
      // yet; English goes last.
      english = bundle
      _AppLocale._setPackBundles(packs + (english.map { [$0] } ?? []))
    #endif
  }

  #if canImport(ObjectiveC)
    @MainActor private static func install() {
      if type(of: Bundle.main) != PackBundle.self {
        PackBundle.addLookups
        object_setClass(Bundle.main, PackBundle.self)
      }
    }
  #else
    @MainActor private static var packs: [Bundle] = []
    @MainActor private static var english: Bundle?
  #endif
}

#if canImport(ObjectiveC)
  /// The pack bundles, read from any thread.
  enum Packs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundles: [Bundle] = []
    nonisolated(unsafe) private static var englishBundle: Bundle?

    static func set(_ new: [Bundle]) { lock.withLock { bundles = new } }
    static var current: [Bundle] { lock.withLock { bundles } }
    static func setEnglish(_ new: Bundle?) { lock.withLock { englishBundle = new } }
    static var english: Bundle? { lock.withLock { englishBundle } }
  }

  /// What the main bundle becomes; its lookups are added at run time (`addLookups`).
  final class PackBundle: Bundle, @unchecked Sendable {
    /// What a pack answers for a key it hasn't: plain letters, since the attributed lookups parse Markdown (a NUL
    /// comes back as U+FFFD).
    nonisolated(unsafe) static let missing = "V57LanguagePackHasNoSuchLine" as NSString

    static func found(_ result: AnyObject?) -> Bool {
      if let string = result as? NSString { return string != missing }
      if let attributed = result as? NSAttributedString { return attributed.string != missing as String }
      return result != nil
    }

    /// What `bundle` answers for a lookup: the pack's line, else the bundle's own answer, unless that is the key or
    /// the caller's default and English has a plural variant for it. `ask` runs the lookup on a bundle with a value.
    /// The bundle itself is never asked with `missing`: NSBundle caches what it answered for a key, value included,
    /// so the next lookup with the caller's default got "V57LanguagePackHasNoSuchLine" (a window's title).
    static func answer(_ bundle: AnyObject, key: AnyObject?, value: AnyObject?, ask: (AnyObject, AnyObject?) -> AnyObject?)
      -> AnyObject?
    {
      for pack in Packs.current {
        let result = ask(pack, missing)
        if found(result) { return result }
      }
      let own = ask(bundle, value)
      guard let english = Packs.english, isKeyItself(own, key: key, value: value) else { return own }
      let result = ask(english, missing)
      return found(result) ? result : own
    }

    /// Whether a bundle's answer is what it says for a key it hasn't: the caller's default, else the key. A plural
    /// line comes back as its format ("%#@value@"), so it never looks like its key.
    static func isKeyItself(_ result: AnyObject?, key: AnyObject?, value: AnyObject?) -> Bool {
      let text: String? =
        if let string = result as? NSString { string as String }
        else if let attributed = result as? NSAttributedString { attributed.string } else { nil }
      guard let text else { return true }
      return text == (key as? NSString) as String? || text == (value as? NSString) as String?
    }

    private static func original(_ name: String) -> (Selector, IMP, UnsafePointer<CChar>)? {
      let selector = NSSelectorFromString(name)
      guard let method = class_getInstanceMethod(Bundle.self, selector), let types = method_getTypeEncoding(method)
      else { return nil }
      return (selector, method_getImplementation(method), types)
    }

    static let addLookups: Void = {
      let subclass: AnyClass = PackBundle.self
      // key, value, table.
      typealias Three = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
      for name in ["localizedStringForKey:value:table:", "localizedAttributedStringForKey:value:table:"] {
        guard let (selector, imp, types) = original(name) else { continue }
        let call = unsafeBitCast(imp, to: Three.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = {
          bundle, key, value, table in
          answer(bundle, key: key, value: value) { call($0, selector, key, $1, table) }
        }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), types)
      }
      // key, value, table, localization(s): a pack has only the app's language, so another language passes through.
      typealias Four = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
      for name in [
        "localizedStringForKey:value:table:localization:", "localizedStringForKey:value:table:localizations:",
        "localizedAttributedStringForKey:value:table:localization:", "_localizedStringForKey:value:table:localizations:",
      ] {
        guard let (selector, imp, types) = original(name) else { continue }
        let call = unsafeBitCast(imp, to: Four.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = {
          bundle, key, value, table, localization in
          answer(bundle, key: key, value: value) { call($0, selector, key, $1, table, localization) }
        }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), types)
      }
      // key, value, table, bundle localizations, out localization, out format configuration.
      let noCache =
        "_localizedStringNoCacheNoMarkdownParsingForKey:value:table:bundleLocalizations:localization:formatSpecifierConfiguration:"
      if let (selector, imp, types) = original(noCache) {
        typealias NoCache = @convention(c) (
          AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, OpaquePointer?, OpaquePointer?
        ) -> AnyObject?
        let call = unsafeBitCast(imp, to: NoCache.self)
        let block:
          @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, OpaquePointer?, OpaquePointer?)
            -> AnyObject? = { bundle, key, value, table, localizations, localization, configuration in
              answer(bundle, key: key, value: value) { target, value in
                // A pack's or English's own languages; the app's for itself.
                let languages: AnyObject? = target === bundle ? localizations : (target as? Bundle)?.localizations as NSArray?
                return call(target, selector, key, value, table, languages, localization, configuration)
              }
            }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), types)
      }
      // key, value, table, bundle localizations, out localization, prevent Markdown.
      let markdown = "_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:"
      if let (selector, imp, types) = original(markdown) {
        typealias Markdown = @convention(c) (
          AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, OpaquePointer?, Bool
        ) -> AnyObject?
        let call = unsafeBitCast(imp, to: Markdown.self)
        let block:
          @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, OpaquePointer?, Bool) ->
            AnyObject? = { bundle, key, value, table, localizations, localization, prevent in
              answer(bundle, key: key, value: value) { target, value in
                let languages: AnyObject? = target === bundle ? localizations : (target as? Bundle)?.localizations as NSArray?
                return call(target, selector, key, value, table, languages, localization, prevent)
              }
            }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), types)
      }
    }()
  }
#endif
