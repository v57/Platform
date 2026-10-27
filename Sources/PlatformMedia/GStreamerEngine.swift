#if os(Linux)
  import CGStreamer
  import CoreGraphics
  import Foundation
  import Observation

  typealias Engine = GStreamerEngine

  /// GStreamer behind `PlatformPlayer`: a `playbin` pipeline whose video sink is an appsink handing BGRx frames to
  /// `PlatformVideoView` (drawn as images), whose audio goes to the default sink (`PLATFORM_MEDIA_AUDIO_SINK` names
  /// another, e.g. `fakesink` on a machine without sound). Track ids are playbin's stream indexes per kind
  /// (`current-audio`, `current-text`). The bus is read on the main queue.
  ///
  /// Needs the GStreamer runtime with playbin (gstreamer1.0-plugins-base) and the codecs' plugins (-good, -bad,
  /// gstreamer1.0-libav); opening fails with a message when a piece is missing.
  @MainActor final class GStreamerEngine: PlayerEngine {
    static var name: String { "GStreamer" }
    static var version: String {
      _ = initialized
      guard let text = gst_version_string() else { return "GStreamer" }
      defer { g_free(text) }
      return String(cString: text)
    }

    private nonisolated static let initialized: Bool = {
      gst_init(nil, nil)
      return true
    }()

    var report: (@MainActor (PlatformPlayer.EngineEvent) -> Void)?
    let output = PlatformVideoOutput()
    private let frames: FrameReceiver
    private var playbin: UnsafeMutablePointer<GstElement>?
    private var bus: UnsafeMutablePointer<GstBus>?
    private var busTimer: DispatchSourceTimer?
    private var isPrerolled = false
    private var isSeeking = false
    private var lastMedia: (Double, [PlatformMediaTrack], Int?, Int?)?

    init() {
      frames = FrameReceiver()
      frames.output = output
    }

    var position: Double {
      guard let playbin else { return 0 }
      var nanoseconds: gint64 = 0
      guard pm_query_position(playbin, &nanoseconds) != 0, nanoseconds >= 0 else { return 0 }
      return Double(nanoseconds) / 1e9
    }

    func open(_ url: URL, volume: Double, muted: Bool, rate: Double) {
      stop()
      _ = Self.initialized
      guard let playbin = gst_element_factory_make("playbin", "platform-media") else {
        report?(.failed("GStreamer's playbin is missing (install gstreamer1.0-plugins-base)."))
        return
      }
      self.playbin = playbin
      let uri: String
      if url.isFileURL, let fileURI = gst_filename_to_uri(url.path, nil) {
        uri = String(cString: fileURI)
        g_free(fileURI)
      } else {
        uri = url.absoluteString
      }
      pm_set_string(playbin, "uri", uri)
      let context = Unmanaged.passUnretained(frames).toOpaque()
      if let sink = pm_frame_sink_new("video/x-raw,format=BGRx", frameCallback, context) {
        pm_set_object(playbin, "video-sink", sink)
      }
      if let name = ProcessInfo.processInfo.environment["PLATFORM_MEDIA_AUDIO_SINK"],
        let sink = gst_element_factory_make(name, "platform-media-audio")
      {
        pm_set_object(playbin, "audio-sink", sink)
      }
      setVolume(volume, muted: muted)
      bus = gst_element_get_bus(playbin)
      isPrerolled = false
      startBusTimer()
      if gst_element_set_state(playbin, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE {
        report?(.failed("The media could not be opened."))
      }
    }

    func play(rate: Double) {
      guard let playbin else { return }
      gst_element_set_state(playbin, GST_STATE_PLAYING)
    }

    func pause() {
      guard let playbin else { return }
      gst_element_set_state(playbin, GST_STATE_PAUSED)
    }

    func seek(to seconds: Double, exact: Bool, rate: Double) {
      guard let playbin else { return }
      isSeeking = true
      _ = pm_seek(playbin, rate, gint64(seconds * 1e9), exact ? 1 : 0)
    }

    func stop() {
      busTimer?.cancel()
      busTimer = nil
      if let playbin {
        // Joins the streaming threads: no frame arrives after this.
        gst_element_set_state(playbin, GST_STATE_NULL)
        pm_object_unref(playbin)
      }
      pm_object_unref(bus)
      playbin = nil
      bus = nil
      isPrerolled = false
      isSeeking = false
      lastMedia = nil
      frames.reset()
      output.frame = nil
    }

    func setVolume(_ volume: Double, muted: Bool) {
      guard let playbin else { return }
      pm_set_double(playbin, "volume", volume)
      pm_set_bool(playbin, "mute", muted ? 1 : 0)
    }

    func setRate(_ rate: Double, playing: Bool) {
      guard let playbin else { return }
      _ = pm_seek(playbin, rate, gint64(position * 1e9), 1)
    }

    func selectAudio(_ id: Int) {
      guard let playbin else { return }
      pm_set_int(playbin, "current-audio", gint(id))
    }

    func selectSubtitle(_ id: Int?) {
      guard let playbin else { return }
      var flags = pm_get_uint(playbin, "flags")
      if let id {
        pm_set_int(playbin, "current-text", gint(id))
        flags |= guint(PM_PLAY_FLAG_TEXT)
      } else {
        flags &= ~guint(PM_PLAY_FLAG_TEXT)
      }
      pm_set_uint(playbin, "flags", flags)
    }

    func poll() {}

    // MARK: Bus

    private func startBusTimer() {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(10))
      timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drainBus() } }
      timer.resume()
      busTimer = timer
    }

    private func drainBus() {
      while let bus, let message = gst_bus_pop(bus) {
        handle(message)
        pm_message_unref(message)
      }
    }

    private func handle(_ message: UnsafeMutablePointer<GstMessage>) {
      guard let playbin else { return }
      let type = pm_message_type(message)
      if type == GST_MESSAGE_ASYNC_DONE {
        if !isPrerolled {
          isPrerolled = true
          let media = readMedia(playbin)
          lastMedia = media
          if let size = videoSize(playbin) { report?(.videoSize(size)) }
          report?(.ready(duration: media.0, tracks: media.1, audio: media.2, subtitle: media.3))
        } else if isSeeking {
          isSeeking = false
          report?(.seeked)
        }
      } else if type == GST_MESSAGE_EOS {
        report?(.ended)
      } else if type == GST_MESSAGE_ERROR {
        let text = pm_message_error(message)
        let error = text.map { String(cString: $0) } ?? "Playback failed."
        g_free(text)
        report?(.failed(error))
      } else if isPrerolled, type == GST_MESSAGE_DURATION_CHANGED || type == GST_MESSAGE_TAG
        || type == GST_MESSAGE_STREAM_START
      {
        refreshMedia(playbin)
      }
    }

    private func refreshMedia(_ playbin: UnsafeMutablePointer<GstElement>) {
      let media = readMedia(playbin)
      if let last = lastMedia, last.0 == media.0, last.1 == media.1, last.2 == media.2, last.3 == media.3 { return }
      lastMedia = media
      report?(.media(duration: media.0, tracks: media.1, audio: media.2, subtitle: media.3))
      if let size = videoSize(playbin) { report?(.videoSize(size)) }
    }

    // MARK: Media info

    private func readMedia(_ playbin: UnsafeMutablePointer<GstElement>) -> (Double, [PlatformMediaTrack], Int?, Int?) {
      var nanoseconds: gint64 = 0
      let duration = pm_query_duration(playbin, &nanoseconds) != 0 && nanoseconds > 0 ? Double(nanoseconds) / 1e9 : 0
      var tracks: [PlatformMediaTrack] = []
      for index in 0..<max(0, Int(pm_get_int(playbin, "n-video"))) {
        let tags = Tags(playbin, "get-video-tags", index)
        tracks.append(
          PlatformMediaTrack(
            id: index, kind: .video, codec: tags["video-codec"], language: tags["language-code"],
            title: tags["title"], isDefault: index == 0))
      }
      for index in 0..<max(0, Int(pm_get_int(playbin, "n-audio"))) {
        let tags = Tags(playbin, "get-audio-tags", index)
        var channels: gint = 0
        var rate: gint = 0
        tracks.append(
          PlatformMediaTrack(
            id: index, kind: .audio, codec: tags["audio-codec"], language: tags["language-code"],
            title: tags["title"],
            channelCount: pm_stream_caps_int(playbin, "get-audio-pad", gint(index), "channels", &channels) != 0
              ? Int(channels) : nil,
            sampleRate: pm_stream_caps_int(playbin, "get-audio-pad", gint(index), "rate", &rate) != 0
              ? Int(rate) : nil,
            isDefault: index == 0))
      }
      for index in 0..<max(0, Int(pm_get_int(playbin, "n-text"))) {
        let tags = Tags(playbin, "get-text-tags", index)
        tracks.append(
          PlatformMediaTrack(
            id: index, kind: .subtitle, codec: tags["subtitle-codec"], language: tags["language-code"],
            title: tags["title"], isDefault: index == 0))
      }
      let audio = Int(pm_get_int(playbin, "current-audio"))
      let showsText = pm_get_uint(playbin, "flags") & guint(PM_PLAY_FLAG_TEXT) != 0
      let text = Int(pm_get_int(playbin, "current-text"))
      return (
        duration, tracks, audio >= 0 && tracks.contains { $0.kind == .audio } ? audio : nil,
        showsText && text >= 0 && tracks.contains { $0.kind == .subtitle } ? text : nil
      )
    }

    private func videoSize(_ playbin: UnsafeMutablePointer<GstElement>) -> CGSize? {
      let index = max(0, pm_get_int(playbin, "current-video"))
      var width: gint = 0
      var height: gint = 0
      guard pm_stream_caps_int(playbin, "get-video-pad", index, "width", &width) != 0,
        pm_stream_caps_int(playbin, "get-video-pad", index, "height", &height) != 0, width > 0, height > 0
      else { return nil }
      return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
  }

  /// A stream's tag list, read by name.
  private final class Tags {
    let list: UnsafeMutablePointer<GstTagList>?

    init(_ playbin: UnsafeMutablePointer<GstElement>, _ signal: String, _ index: Int) {
      list = pm_stream_tags(playbin, signal, gint(index))
    }

    deinit { pm_tags_unref(list) }

    subscript(tag: String) -> String? {
      guard let list, let value = pm_tag_string(list, tag) else { return nil }
      defer { g_free(value) }
      return String(cString: value)
    }
  }

  /// The picture `PlatformVideoView` draws on Linux: the newest frame and its display aspect.
  @MainActor @Observable final class PlatformVideoOutput {
    var frame: CGImage?
    var aspect: CGFloat = 16 / 9
  }

  /// Takes frames on GStreamer's streaming thread and publishes the newest one on the main queue (frames that
  /// arrive while one is waiting replace it).
  final class FrameReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (CGImage, CGFloat)?
    private var scheduled = false
    private var generation = 0
    @MainActor weak var output: PlatformVideoOutput?

    func receive(_ data: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, aspect: CGFloat) {
      let bytes = Data(bytes: data, count: stride * height)
      guard let provider = CGDataProvider(data: bytes),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { return }
      let generation: Int? = lock.withLock {
        pending = (image, aspect)
        guard !scheduled else { return nil }
        scheduled = true
        return self.generation
      }
      guard let generation else { return }
      DispatchQueue.main.async { [self] in
        let frame: (CGImage, CGFloat)? = lock.withLock {
          scheduled = false
          defer { pending = nil }
          return generation == self.generation ? pending : nil
        }
        guard let frame else { return }
        MainActor.assumeIsolated {
          output?.frame = frame.0
          if output?.aspect != frame.1 { output?.aspect = frame.1 }
        }
      }
    }

    /// Drops a frame still on its way (the pipeline was torn down).
    func reset() {
      lock.withLock {
        generation += 1
        pending = nil
      }
    }
  }

  private let frameCallback: pm_frame_callback = { context, data, width, height, stride, parN, parD in
    guard let context, let data, width > 0, height > 0 else { return }
    let receiver = Unmanaged<FrameReceiver>.fromOpaque(context).takeUnretainedValue()
    let pixelAspect = parN > 0 && parD > 0 ? CGFloat(parN) / CGFloat(parD) : 1
    receiver.receive(
      data, width: Int(width), height: Int(height), stride: Int(stride),
      aspect: CGFloat(width) * pixelAspect / CGFloat(height))
  }
#endif
