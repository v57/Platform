#if canImport(AVFoundation)
  import AVFoundation
  import Foundation

  typealias Engine = AVFoundationEngine

  /// AVPlayer behind `PlatformPlayer`: tracks from the asset's audible and legible media selection groups (a track's
  /// id is its option's index in the group), the picture through an AVPlayerLayer (`PlatformVideoView`).
  @MainActor final class AVFoundationEngine: PlayerEngine {
    static var name: String { "AVFoundation" }
    static var version: String { ProcessInfo.processInfo.operatingSystemVersionString }

    var report: (@MainActor (PlatformPlayer.EngineEvent) -> Void)?
    let player = AVPlayer()
    private var item: AVPlayerItem?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: (any NSObjectProtocol)?
    private var audible: AVMediaSelectionGroup?
    private var legible: AVMediaSelectionGroup?
    private var generation = 0

    init() {
      player.appliesMediaSelectionCriteriaAutomatically = false
    }

    var position: Double {
      let seconds = player.currentTime().seconds
      return seconds.isFinite ? seconds : 0
    }

    func open(_ url: URL, volume: Double, muted: Bool, rate: Double) {
      stop()
      generation += 1
      let generation = generation
      let asset = AVURLAsset(url: url)
      let item = AVPlayerItem(asset: asset)
      self.item = item
      setVolume(volume, muted: muted)
      player.defaultRate = Float(rate)
      observations = [
        item.observe(\.status) { [weak self] item, _ in
          let status = item.status
          let message = item.error?.localizedDescription
          Task { @MainActor in self?.statusChanged(status, message: message, generation: generation) }
        },
        item.observe(\.presentationSize) { [weak self] item, _ in
          let size = item.presentationSize
          Task { @MainActor in
            guard self?.generation == generation else { return }
            self?.report?(.videoSize(size))
          }
        },
      ]
      endObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard self?.generation == generation else { return }
          self?.report?(.ended)
        }
      }
      player.replaceCurrentItem(with: item)
    }

    private func statusChanged(_ status: AVPlayerItem.Status, message: String?, generation: Int) {
      guard generation == self.generation else { return }
      switch status {
      case .readyToPlay:
        Task { await loadMedia(generation: generation) }
      case .failed:
        report?(.failed(message ?? "The media could not be played."))
      default: break
      }
    }

    /// The length and the streams, once the item is ready.
    private func loadMedia(generation: Int) async {
      guard let item else { return }
      let asset = item.asset
      let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
      var tracks: [PlatformMediaTrack] = []
      for (index, track) in videoTracks.enumerated() {
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        tracks.append(
          PlatformMediaTrack(
            id: index, kind: .video, codec: formats.first.map { Self.fourCC($0.mediaSubType.rawValue) },
            isDefault: index == 0))
      }
      let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
      let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
      guard generation == self.generation else { return }
      self.audible = audible
      self.legible = legible
      if let audible {
        for (index, option) in audible.options.enumerated() {
          tracks.append(track(option, index: index, kind: .audio, group: audible))
        }
      } else {
        // No selection group: the asset's own audio tracks, the first one playing.
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        for (index, track) in audioTracks.enumerated() {
          let formats = (try? await track.load(.formatDescriptions)) ?? []
          let basic = formats.first?.audioStreamBasicDescription
          tracks.append(
            PlatformMediaTrack(
              id: index, kind: .audio, codec: formats.first.map { Self.fourCC($0.mediaSubType.rawValue) },
              language: try? await track.load(.languageCode), channelCount: basic.map { Int($0.mChannelsPerFrame) },
              sampleRate: basic.map { Int($0.mSampleRate) }, isDefault: index == 0))
        }
      }
      if let legible {
        for (index, option) in legible.options.enumerated() {
          tracks.append(track(option, index: index, kind: .subtitle, group: legible))
        }
      }
      let duration = (try? await asset.load(.duration))?.seconds ?? 0
      guard generation == self.generation else { return }
      let audio = audible.flatMap { group in
        item.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
      } ?? (tracks.contains { $0.kind == .audio } ? 0 : nil)
      let subtitle = legible.flatMap { group in
        item.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
      }
      report?(
        .ready(duration: duration.isFinite ? duration : 0, tracks: tracks, audio: audio, subtitle: subtitle))
    }

    private func track(_ option: AVMediaSelectionOption, index: Int, kind: PlatformMediaTrack.Kind, group: AVMediaSelectionGroup)
      -> PlatformMediaTrack
    {
      PlatformMediaTrack(
        id: index, kind: kind,
        codec: (option.mediaSubTypes.first as? NSNumber).map { Self.fourCC($0.uint32Value) },
        language: option.extendedLanguageTag ?? option.locale?.identifier, title: option.displayName,
        isDefault: group.defaultOption == option)
    }

    /// "avc1", "mp4a", ...
    private static func fourCC(_ value: FourCharCode) -> String {
      let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
      return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func play(rate: Double) {
      player.defaultRate = Float(rate)
      player.play()
    }

    func pause() { player.pause() }

    func seek(to seconds: Double, exact: Bool, rate: Double) {
      let tolerance: CMTime = exact ? .zero : .positiveInfinity
      let generation = generation
      player.seek(
        to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance
      ) { [weak self] _ in
        Task { @MainActor in
          guard self?.generation == generation else { return }
          self?.report?(.seeked)
        }
      }
    }

    func stop() {
      generation += 1
      player.pause()
      player.replaceCurrentItem(with: nil)
      observations = []
      if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
      endObserver = nil
      item = nil
      audible = nil
      legible = nil
    }

    func setVolume(_ volume: Double, muted: Bool) {
      player.volume = Float(volume)
      player.isMuted = muted
    }

    func setRate(_ rate: Double, playing: Bool) {
      player.defaultRate = Float(rate)
      if playing { player.rate = Float(rate) }
    }

    func selectAudio(_ id: Int) {
      guard let item, let audible, audible.options.indices.contains(id) else { return }
      item.select(audible.options[id], in: audible)
    }

    func selectSubtitle(_ id: Int?) {
      guard let item, let legible else { return }
      item.select(id.flatMap { legible.options.indices.contains($0) ? legible.options[$0] : nil }, in: legible)
    }

    func poll() {}
  }
#endif
