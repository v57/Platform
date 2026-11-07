import Foundation

/// Whether a downloaded translation can be formatted with its key's arguments. A translation is data from the
/// network, and a format specifier that doesn't fit (`%@` where the app passes a number, `%s`, `%n`) crashes
/// `String(format:)` or reads the wrong memory, so every line is checked before it's used and a misfit is dropped:
/// its key then shows in English. It also catches a translator's or a model's slip.
///
/// A plain line fits when each of its arguments (by position, `%2$@` or in order) is one of the key's, of the same
/// kind; it may leave some out. A plural entry (`.stringsdict`) fits when every specifier in it is of a kind the key
/// has, at most as often, since Xcode writes plural forms that drop the number ("Eine Datei in %@").
public enum FormatCheck {
  enum Kind: Hashable {
    case object, int32, int64, double, longDouble, cString, pointer
  }

  struct Specifier: Hashable {
    var position: Int?
    var kind: Kind
  }

  /// The arguments `format` reads, in order; nil when one is never safe (`%n`, which writes memory).
  static func specifiers(in format: String) -> [Specifier]? {
    var result: [Specifier] = []
    let scalars = Array(format.unicodeScalars)
    var index = 0
    func digits() -> Int? {
      var value: Int?
      while index < scalars.count, scalars[index].isASCII, let digit = Int(String(scalars[index])) {
        value = (value ?? 0) * 10 + digit
        index += 1
      }
      return value
    }
    while index < scalars.count {
      guard scalars[index] == "%" else {
        index += 1
        continue
      }
      let start = index
      index += 1
      guard index < scalars.count else { break }
      if scalars[index] == "%" {
        index += 1
        continue
      }
      // %1$…: a position.
      var position: Int?
      let mark = index
      if let number = digits(), index < scalars.count, scalars[index] == "$" {
        position = number
        index += 1
      } else {
        index = mark
      }
      // A stringsdict variable, %#@name@: its kind comes from the entry, not the format.
      if index < scalars.count, scalars[index] == "#" {
        while index < scalars.count, scalars[index] != "@" { index += 1 }
        index += 1
        while index < scalars.count, scalars[index] != "@" { index += 1 }
        index += 1
        continue
      }
      while index < scalars.count, "-+ #0'".unicodeScalars.contains(scalars[index]) { index += 1 }
      // A width or precision of `*` reads an int argument first.
      if index < scalars.count, scalars[index] == "*" {
        result.append(Specifier(position: nil, kind: .int32))
        index += 1
      } else {
        _ = digits()
      }
      if index < scalars.count, scalars[index] == "." {
        index += 1
        if index < scalars.count, scalars[index] == "*" {
          result.append(Specifier(position: nil, kind: .int32))
          index += 1
        } else {
          _ = digits()
        }
      }
      var length = ""
      while index < scalars.count, "hlqLztj".unicodeScalars.contains(scalars[index]) {
        length.unicodeScalars.append(scalars[index])
        index += 1
      }
      guard index < scalars.count else { break }
      let conversion = scalars[index]
      index += 1
      let wide = ["l", "ll", "q", "z", "t", "j"].contains(length)
      switch conversion {
      case "@": result.append(Specifier(position: position, kind: .object))
      case "d", "i", "u", "x", "X", "o":
        result.append(Specifier(position: position, kind: wide ? .int64 : .int32))
      case "D", "U", "O": result.append(Specifier(position: position, kind: .int64))
      case "c", "C": result.append(Specifier(position: position, kind: .int32))
      case "f", "F", "e", "E", "g", "G", "a", "A":
        result.append(Specifier(position: position, kind: length == "L" ? .longDouble : .double))
      case "s", "S": result.append(Specifier(position: position, kind: .cString))
      case "p": result.append(Specifier(position: position, kind: .pointer))
      case "n": return nil
      default:
        // Not a specifier ("100 %" at the end of a sentence): printed as it is.
        index = start + 1
      }
    }
    return result
  }

  /// The kind of each argument by its number (1, 2, …); nil when two specifiers read one argument as different kinds.
  static func arguments(_ specifiers: [Specifier]) -> [Int: Kind]? {
    var result: [Int: Kind] = [:]
    var next = 1
    for specifier in specifiers {
      let number = specifier.position ?? next
      if specifier.position == nil { next += 1 }
      if let known = result[number], known != specifier.kind { return nil }
      result[number] = specifier.kind
    }
    return result
  }

  /// Kinds that crash when the argument is something else (a number read as an object or a C string).
  static let dangerous: Set<Kind> = [.object, .cString, .pointer]

  /// Whether `translation` can be formatted with `key`'s arguments.
  public static func fits(_ translation: String, key: String) -> Bool {
    guard let theirs = specifiers(in: translation), let arguments = arguments(theirs) else { return false }
    guard let ours = specifiers(in: key), let keyArguments = self.arguments(ours) else {
      return translation == key
    }
    if keyArguments.isEmpty {
      // A key without arguments is rarely formatted: allow what can't crash ("100 % d'espace" reads as "% d").
      return !arguments.values.contains { dangerous.contains($0) }
    }
    return arguments.allSatisfy { keyArguments[$0.key] == $0.value }
  }

  /// Whether a `.stringsdict` entry (its format and every plural form) fits `key`'s arguments.
  public static func fits(pluralEntry entry: [String: Any], key: String) -> Bool {
    guard let format = entry["NSStringLocalizedFormatKey"] as? String else { return false }
    guard let ours = specifiers(in: key) else { return false }
    var keyKinds: [Kind: Int] = [:]
    for specifier in ours { keyKinds[specifier.kind, default: 0] += 1 }
    var strings = [format]
    for case let (name, variable as [String: Any]) in entry where name != "NSStringLocalizedFormatKey" {
      for case let (form, value as String) in variable where !form.hasPrefix("NSStringFormat") {
        strings.append(value)
      }
    }
    for string in strings {
      guard let theirs = specifiers(in: string) else { return false }
      var kinds: [Kind: Int] = [:]
      for specifier in theirs {
        kinds[specifier.kind, default: 0] += 1
        if let position = specifier.position, position > ours.count { return false }
      }
      if kinds.contains(where: { keyKinds[$0.key, default: 0] < $0.value }) { return false }
    }
    return true
  }

  /// A downloaded `.strings` table (text, XML or binary) with the lines that don't fit dropped.
  public static func checkedStrings(_ data: Data) throws -> (table: [String: String], dropped: [String]) {
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let table = parsed as? [String: Any] else { throw CheckError.notATable }
    var kept: [String: String] = [:]
    var dropped: [String] = []
    for (key, value) in table {
      if let value = value as? String, fits(value, key: key) {
        kept[key] = value
      } else {
        dropped.append(key)
      }
    }
    return (kept, dropped.sorted())
  }

  /// A downloaded `.stringsdict` with the entries that don't fit dropped.
  public static func checkedStringsdict(_ data: Data) throws -> (table: [String: Any], dropped: [String]) {
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let table = parsed as? [String: Any] else { throw CheckError.notATable }
    var kept: [String: Any] = [:]
    var dropped: [String] = []
    for (key, value) in table {
      if let entry = value as? [String: Any], fits(pluralEntry: entry, key: key) {
        kept[key] = entry
      } else {
        dropped.append(key)
      }
    }
    return (kept, dropped.sorted())
  }

  enum CheckError: Error {
    case notATable
  }
}
