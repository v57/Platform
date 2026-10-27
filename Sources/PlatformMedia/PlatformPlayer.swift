import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Where a `PlatformPlayer` is.
public enum PlatformPlayerState: Equatable, Sendable {
  /// Nothing open.
  case idle
  /// A file is opening: read until its length, tracks and first picture are known.
  case loading
  /// Open and paused on its first picture, not started yet.
  case ready
  case playing
  case paused
  /// Played to the end; `play()` starts it over.
  case ended
  /// Opening or playing failed; see `errorMessage`.
  case failed
}

/// One stream of the open media.
public struct PlatformMediaTrack: Identifiable, Hashable, Sendable {
  public enum Kind: String, Sendable { case video, audio, subtitle }

  /// The stream's index among the media's streams of its kind (0, 1, ...): stable for one file.
  public let id: Int
  public let kind: Kind
  /// The codec as the engine names it ("H.264", "aac", ...), when known.
  public let codec: String?
  /// ISO 639 language code, when the file tags one.
  public let language: String?
  public let title: String?
  /// Audio only.
  public let channelCount: Int?
  /// Audio only, in Hz.
  public let sampleRate: Int?
  public let isDefault: Bool

  public init(
    id: Int, kind: Kind, codec: String? = nil, language: String? = nil, title: String? = nil,
    channelCount: Int? = nil, sampleRate: Int? = nil, isDefault: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.codec = codec
    self.language = language
    self.title = title
    self.channelCount = channelCount
    self.sampleRate = sampleRate
    self.isDefault = isDefault
  }
}

/// What changed on a `PlatformPlayer` (`onEvent`).
public enum PlatformPlayerEvent: Equatable, Sendable {
  /// `state` changed.
  case state
  /// The position moved: every `timeInterval` while playing, and after a seek.
  case time
  /// `duration`, `tracks` or the selected tracks changed.
  case media
  /// `videoSize` changed.
  case videoSize
  /// Playback reached the end.
  case ended
  /// Opening or playback failed with this message.
  case failed(String)
}

/// The error `PlatformPlayer.open` throws.
public struct PlatformPlayerError: Error, LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Plays a media file or URL: transport, volume, rate, audio and subtitle tracks, and the picture through
/// `PlatformVideoView`. AVFoundation (AVPlayer) on Apple platforms, GStreamer (playbin) on Linux.
///
/// Driven from the main actor; report changes through `onEvent`.
@MainActor public final class PlatformPlayer {
  /// The engine behind this build ("AVFoundation", "GStreamer").
  public static var engineName: String { Engine.name }
  /// The engine's version ("GStreamer 1.24.2"; the OS version on Apple platforms).
  public static var engineVersion: String { Engine.version }

  public private(set) var state: PlatformPlayerState = .idle {
    didSet { if state != oldValue { send(.state) } }
  }
  /// The media open, nil while idle.
  public private(set) var url: URL?
  /// Seconds into the media (live).
  public var position: Double {
    guard state != .idle else { return 0 }
    if let seekTarget { return seekTarget }
    let value = engine.position
    return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
  }
  /// The media's length in seconds, 0 while unknown.
  public private(set) var duration: Double = 0
  /// The picture's display size in pixels (the pixel aspect applied), zero without video.
  public private(set) var videoSize: CGSize = .zero
  public private(set) var tracks: [PlatformMediaTrack] = []
  public var videoTracks: [PlatformMediaTrack] { tracks.filter { $0.kind == .video } }
  public var audioTracks: [PlatformMediaTrack] { tracks.filter { $0.kind == .audio } }
  public var subtitleTracks: [PlatformMediaTrack] { tracks.filter { $0.kind == .subtitle } }
  /// The audio track playing, nil without audio.
  public private(set) var audioTrackID: Int?
  /// The subtitle track shown, nil while subtitles are off.
  public private(set) var subtitleTrackID: Int?
  /// The last failure's message.
  public private(set) var errorMessage: String?
  public var isPlaying: Bool { state == .playing }

  /// Output volume, 0...1.
  public var volume: Double = 1 {
    didSet { engine.setVolume(min(max(volume, 0), 1), muted: isMuted) }
  }
  public var isMuted = false {
    didSet { engine.setVolume(min(max(volume, 0), 1), muted: isMuted) }
  }
  /// Playback speed (1 = normal), kept across files.
  public var rate: Double = 1 {
    didSet { if rate > 0, rate != oldValue { engine.setRate(rate, playing: isPlaying) } }
  }
  /// How often `.time` fires while playing, in seconds.
  public var timeInterval: TimeInterval = 0.25 {
    didSet { if isPlaying { startClock() } }
  }
  /// Called on the main actor for every change.
  public var onEvent: (@MainActor (PlatformPlayerEvent) -> Void)?

  let engine: Engine
  private var opening: CheckedContinuation<Void, any Error>?
  private var clock: DispatchSourceTimer?
  /// Where the last seek goes until the engine reports a position there (a paused engine reports the old one
  /// until the seek lands).
  private var seekTarget: Double?

  public init() {
    engine = Engine()
    engine.report = { [weak self] event in self?.handle(event) }
  }

  // MARK: Transport

  /// Opens `url` (a file or a network URL the engine can read) and returns once it's ready to play, paused on
  /// its first picture. Throws when it can't be played; opening another file cancels this one.
  public func open(_ url: URL) async throws {
    if state != .idle { stop() }
    self.url = url
    errorMessage = nil
    state = .loading
    try await withCheckedThrowingContinuation { continuation in
      opening = continuation
      engine.open(url, volume: volume, muted: isMuted, rate: rate)
    }
  }

  public func play() {
    guard state != .idle, state != .loading, state != .failed else { return }
    if state == .ended { seek(to: 0, exact: true) }
    engine.play(rate: rate)
    state = .playing
    startClock()
  }

  public func pause() {
    guard state == .playing || state == .ready || state == .ended else { return }
    engine.pause()
    if state == .playing { state = .paused }
    stopClock()
  }

  /// Seeks to `seconds`: to the nearest keyframe (fast, for scrubbing), or exactly with `exact`.
  public func seek(to seconds: Double, exact: Bool = false) {
    guard state != .idle, state != .loading, state != .failed else { return }
    let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
    seekTarget = target
    engine.seek(to: target, exact: exact, rate: rate)
    if state == .ended { state = .paused }
    send(.time)
  }

  /// Closes the media.
  public func stop() {
    if let opening {
      self.opening = nil
      opening.resume(throwing: CancellationError())
    }
    stopClock()
    engine.stop()
    url = nil
    duration = 0
    videoSize = .zero
    tracks = []
    audioTrackID = nil
    subtitleTrackID = nil
    seekTarget = nil
    state = .idle
    send(.media)
  }

  public func selectAudioTrack(_ id: Int) {
    guard audioTracks.contains(where: { $0.id == id }), id != audioTrackID else { return }
    audioTrackID = id
    engine.selectAudio(id)
    send(.media)
  }

  /// nil turns subtitles off.
  public func selectSubtitleTrack(_ id: Int?) {
    if let id, !subtitleTracks.contains(where: { $0.id == id }) { return }
    subtitleTrackID = id
    engine.selectSubtitle(id)
    send(.media)
  }

  // MARK: Engine events

  enum EngineEvent {
    /// Opened: the length, the streams and the ones selected.
    case ready(duration: Double, tracks: [PlatformMediaTrack], audio: Int?, subtitle: Int?)
    case media(duration: Double, tracks: [PlatformMediaTrack], audio: Int?, subtitle: Int?)
    case videoSize(CGSize)
    /// A seek landed.
    case seeked
    case ended
    case failed(String)
  }

  private func handle(_ event: EngineEvent) {
    switch event {
    case .ready(let duration, let tracks, let audio, let subtitle):
      guard state == .loading else { return }
      apply(duration: duration, tracks: tracks, audio: audio, subtitle: subtitle)
      state = .ready
      opening?.resume()
      opening = nil
    case .media(let duration, let tracks, let audio, let subtitle):
      guard state != .idle, state != .loading else { return }
      apply(duration: duration, tracks: tracks, audio: audio, subtitle: subtitle)
    case .videoSize(let size):
      guard size != videoSize else { return }
      videoSize = size
      send(.videoSize)
    case .seeked:
      seekTarget = nil
      send(.time)
    case .ended:
      guard state != .idle, state != .loading else { return }
      seekTarget = nil
      stopClock()
      state = .ended
      send(.time)
      send(.ended)
    case .failed(let message):
      guard state != .idle else { return }
      stopClock()
      errorMessage = message
      state = .failed
      if let opening {
        self.opening = nil
        opening.resume(throwing: PlatformPlayerError(message))
      }
      send(.failed(message))
    }
  }

  private func apply(duration: Double, tracks: [PlatformMediaTrack], audio: Int?, subtitle: Int?) {
    let changed =
      duration != self.duration || tracks != self.tracks || audio != audioTrackID || subtitle != subtitleTrackID
    self.duration = duration
    self.tracks = tracks
    audioTrackID = audio
    subtitleTrackID = subtitle
    if changed { send(.media) }
  }

  private func send(_ event: PlatformPlayerEvent) { onEvent?(event) }

  // MARK: Clock

  private func startClock() {
    clock?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + timeInterval, repeating: timeInterval, leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.engine.poll()
        self.send(.time)
      }
    }
    timer.resume()
    clock = timer
  }

  private func stopClock() {
    clock?.cancel()
    clock = nil
  }
}

/// The engine contract each backend implements (`Engine` is the platform's).
@MainActor protocol PlayerEngine: AnyObject {
  static var name: String { get }
  static var version: String { get }
  var report: (@MainActor (PlatformPlayer.EngineEvent) -> Void)? { get set }
  var position: Double { get }
  func open(_ url: URL, volume: Double, muted: Bool, rate: Double)
  func play(rate: Double)
  func pause()
  func seek(to seconds: Double, exact: Bool, rate: Double)
  func stop()
  func setVolume(_ volume: Double, muted: Bool)
  func setRate(_ rate: Double, playing: Bool)
  func selectAudio(_ id: Int)
  func selectSubtitle(_ id: Int?)
  /// Called with the clock: a chance to pick up what the engine doesn't report on its own.
  func poll()
}
