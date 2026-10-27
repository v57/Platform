import Foundation
import Testing

@testable import PlatformMedia

@MainActor struct PlatformPlayerTests {
  @Test func startsIdle() {
    let player = PlatformPlayer()
    #expect(player.state == .idle)
    #expect(player.position == 0)
    #expect(player.tracks.isEmpty)
    #expect(!PlatformPlayer.engineName.isEmpty)
  }

  @Test func failsOnAMissingFile() async {
    let player = PlatformPlayer()
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp4")
    await #expect(throws: (any Error).self) { try await player.open(url) }
    #expect(player.state == .failed)
  }

  /// Plays `PLATFORM_MEDIA_TEST_FILE` for a moment: it opens with a length and a video track, and the position
  /// moves while playing.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PLATFORM_MEDIA_TEST_FILE"] != nil))
  func playsAFile() async throws {
    let path = ProcessInfo.processInfo.environment["PLATFORM_MEDIA_TEST_FILE"]!
    let player = PlatformPlayer()
    player.isMuted = true
    try await player.open(URL(fileURLWithPath: path))
    #expect(player.state == .ready)
    #expect(player.duration > 0)
    #expect(!player.videoTracks.isEmpty)
    player.play()
    try await Task.sleep(for: .seconds(1.5))
    #expect(player.position > 0.5)
    player.seek(to: player.duration / 2, exact: true)
    player.pause()
    try await Task.sleep(for: .seconds(1))
    #expect(abs(player.position - player.duration / 2) < 1)
    player.stop()
    #expect(player.state == .idle)
  }
}
