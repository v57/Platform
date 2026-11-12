import Foundation

/// The English plural variants of every v57 source's count keys: `%lld servers` → "1 server" / "2 servers".
///
/// Apps bundle no English tables (a key is its English text, which the code holds), so without these a count would
/// read "1 servers". `English/en.lproj/Localizable.stringsdict` is written by v57/Localizations' `Scripts/build` from
/// the catalogs (plural keys only, every source's in one table: keys are the English text) and ships as this
/// library's resource, so every app that links it gets them, in Debug and Release builds alike.
enum EnglishPlurals {
  /// The folder holding `en.lproj`, opened as a bundle; nil when the build left this library's resources out (a
  /// Windows or Linux package that doesn't copy them), and then counts read as their keys, as before.
  static let bundle: Bundle? = {
    // Not `Bundle.module`: its accessor stops the app when the resource bundle is missing.
    let names = ["Platform_PlatformLanguages.bundle", "Platform_PlatformLanguages.resources"]
    var places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
    // `swift test`: the resource bundle sits beside the test bundle.
    let own = Bundle(for: Marker.self)
    places += [own.resourceURL, own.bundleURL.deletingLastPathComponent()]
    for place in places.compactMap({ $0 }) {
      for name in names {
        guard let resources = Bundle(url: place.appendingPathComponent(name)) else { continue }
        let folder = (resources.resourceURL ?? resources.bundleURL).appendingPathComponent("English")
        let table = folder.appendingPathComponent("en.lproj/Localizable.stringsdict")
        if FileManager.default.fileExists(atPath: table.path), let english = Bundle(url: folder) { return english }
      }
    }
    return nil
  }()

  private final class Marker {}
}
