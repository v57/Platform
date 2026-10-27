import PlatformKit
import Testing

@Test func currentPlatform() {
  #if os(macOS)
  #expect(Platform.current == .macOS)
  #elseif os(Linux)
  #expect(Platform.current == .linux)
  #endif
}
