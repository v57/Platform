import Foundation

#if canImport(MediaPlayer)
  import MediaPlayer
#elseif os(Linux)
  import CGio
#endif

/// The app as the system's Now Playing app: what plays (title, length, position, playing or paused) for the
/// system's media controls, and the media keys (play, pause, next, previous) routed to the app.
/// MPNowPlayingInfoCenter and MPRemoteCommandCenter on Apple platforms; an MPRIS server on the session bus on Linux
/// (`org.mpris.MediaPlayer2.<name>.instance<pid>`), which desktops drive from their media keys and widgets. A
/// desktop without a session bus just doesn't see it.
@MainActor public final class NowPlaying {
  public enum Command: Sendable { case play, pause, togglePlayPause, nextTrack, previousTrack }

  /// What plays.
  public struct Item: Equatable, Sendable {
    public var title: String
    /// Seconds, 0 while unknown.
    public var duration: Double
    public var position: Double
    public var isPlaying: Bool

    public init(title: String, duration: Double, position: Double, isPlaying: Bool) {
      self.title = title
      self.duration = duration
      self.position = position
      self.isPlaying = isPlaying
    }
  }

  private let handler: @MainActor (Command) -> Bool
  #if os(Linux)
    private var server: UnsafeMutablePointer<pm_mpris>?
  #endif

  /// Starts taking the media keys: `handler` runs each command and returns whether it could. `name` names the
  /// player to the desktop (the app's name).
  public init(name: String, handler: @escaping @MainActor (Command) -> Bool) {
    self.handler = handler
    #if canImport(MediaPlayer)
      let center = MPRemoteCommandCenter.shared()
      let commands: [(MPRemoteCommand, Command)] = [
        (center.playCommand, .play), (center.pauseCommand, .pause),
        (center.togglePlayPauseCommand, .togglePlayPause), (center.nextTrackCommand, .nextTrack),
        (center.previousTrackCommand, .previousTrack),
      ]
      for (remote, command) in commands {
        remote.addTarget { [weak self] _ in
          MainActor.assumeIsolated { self?.handler(command) == true ? .success : .commandFailed }
        }
      }
    #elseif os(Linux)
      let suffix = name.filter { $0.isLetter || $0.isNumber }
      server = pm_mpris_new(
        "\(suffix.isEmpty ? "App" : suffix).instance\(ProcessInfo.processInfo.processIdentifier)", name,
        mprisCommand, Unmanaged.passUnretained(self).toOpaque())
    #endif
  }

  isolated deinit {
    #if os(Linux)
      pm_mpris_free(server)
    #endif
  }

  /// What plays now; nil when nothing does.
  public func update(_ item: Item?) {
    #if canImport(MediaPlayer)
      let center = MPNowPlayingInfoCenter.default()
      guard let item else {
        center.nowPlayingInfo = nil
        #if os(macOS)
          center.playbackState = .stopped
        #endif
        return
      }
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: item.title,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: item.position,
        MPNowPlayingInfoPropertyPlaybackRate: item.isPlaying ? 1.0 : 0.0,
      ]
      if item.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = item.duration }
      center.nowPlayingInfo = info
      #if os(macOS)
        center.playbackState = item.isPlaying ? .playing : .paused
      #endif
    #elseif os(Linux)
      guard let server else { return }
      pm_mpris_update(
        server, item == nil ? 0 : 1, item?.title, gint64((item?.duration ?? 0) * 1e6),
        gint64((item?.position ?? 0) * 1e6), item == nil ? "Stopped" : item!.isPlaying ? "Playing" : "Paused")
    #endif
  }

  fileprivate func run(_ method: String) {
    let command: Command? =
      switch method {
      case "Play": .play
      case "Pause", "Stop": .pause
      case "PlayPause": .togglePlayPause
      case "Next": .nextTrack
      case "Previous": .previousTrack
      default: nil
      }
    if let command { _ = handler(command) }
  }
}

#if os(Linux)
  /// MPRIS method calls arrive on the main thread (GDBus dispatches on the main context, which GTK runs).
  private let mprisCommand: pm_mpris_command = { context, method in
    guard let context, let method else { return }
    let name = String(cString: method)
    let nowPlaying = Unmanaged<NowPlaying>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { nowPlaying.run(name) }
  }
#endif
