import Foundation

#if canImport(ObjectiveC)
  import ObjectiveC
#endif
#if !canImport(Darwin)
  import SwiftUI
#endif

/// Puts a language pack's bundles in front of the main bundle's own tables.
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
  @MainActor static func use(_ bundles: [Bundle]) {
    #if canImport(ObjectiveC)
      Packs.set(bundles)
      if !bundles.isEmpty, type(of: Bundle.main) != PackBundle.self {
        PackBundle.addLookups
        object_setClass(Bundle.main, PackBundle.self)
      }
    #else
      _AppLocale._setPackBundles(bundles)
    #endif
  }
}

#if canImport(ObjectiveC)
  /// The pack bundles, read from any thread.
  enum Packs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundles: [Bundle] = []

    static func set(_ new: [Bundle]) { lock.withLock { bundles = new } }
    static var current: [Bundle] { lock.withLock { bundles } }
  }

  /// What the main bundle becomes; its lookups are added at run time (`addLookups`).
  final class PackBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static let missing = "\u{0}missing" as NSString

    static func found(_ result: AnyObject?) -> Bool {
      if let string = result as? NSString { return string != missing }
      if let attributed = result as? NSAttributedString { return attributed.string != missing as String }
      return result != nil
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
          for pack in Packs.current {
            let result = call(pack, selector, key, missing, table)
            if found(result) { return result }
          }
          return call(bundle, selector, key, value, table)
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
          for pack in Packs.current {
            let result = call(pack, selector, key, missing, table, localization)
            if found(result) { return result }
          }
          return call(bundle, selector, key, value, table, localization)
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
              for pack in Packs.current {
                let result = call(
                  pack, selector, key, missing, table, pack.localizations as NSArray, localization, configuration)
                if found(result) { return result }
              }
              return call(bundle, selector, key, value, table, localizations, localization, configuration)
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
              for pack in Packs.current {
                let result = call(pack, selector, key, missing, table, pack.localizations as NSArray, localization, prevent)
                if found(result) { return result }
              }
              return call(bundle, selector, key, value, table, localizations, localization, prevent)
            }
        class_addMethod(subclass, selector, imp_implementationWithBlock(block), types)
      }
    }()
  }
#endif
