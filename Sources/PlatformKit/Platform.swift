/// The platform this build runs on.
public enum Platform: String, Sendable, CaseIterable {
  case macOS, iOS, linux, windows, android

  public static var current: Platform {
    #if os(macOS)
    .macOS
    #elseif os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
    .iOS
    #elseif os(Android)
    .android
    #elseif os(Linux)
    .linux
    #elseif os(Windows)
    .windows
    #endif
  }

  /// A desktop with windows, a pointer and a keyboard (not a phone or tablet).
  public var isDesktop: Bool { self == .macOS || self == .linux || self == .windows }
}
