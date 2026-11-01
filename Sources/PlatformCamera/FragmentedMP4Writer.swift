import Foundation

#if canImport(AVFoundation)
  @preconcurrency import AVFoundation

  /// Writes encoded H.264 or HEVC frames, as they are, into fragmented MP4 (AVAssetWriter's HLS profile): an initialization
  /// fragment, then one media fragment per `segmentDuration` that starts at a keyframe. An initialization fragment
  /// followed by media fragments, written one after the other, is a playable MP4 file; HomeKit Secure Video and HLS
  /// take the same fragments. Frames before the first keyframe are skipped; a change of parameter sets (another
  /// picture size) starts over with a new initialization fragment.
  public final class FragmentedMP4Writer: NSObject, @unchecked Sendable, AVAssetWriterDelegate {
    public let segmentDuration: Double
    /// Called on AVFoundation's queue, in order
    public var onFragment: (@Sendable (MP4Fragment) -> Void)?

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    public init(segmentDuration: Double = 1) {
      self.segmentDuration = segmentDuration
    }

    public func append(_ frame: EncodedVideoFrame) {
      lock.withLock {
        if frame.isKeyframe, frame.parameterSets != parameterSets {
          start(with: frame)
        }
        guard let input, let formatDescription, input.isReadyForMoreMediaData,
          let sample = frame.sampleBuffer(description: formatDescription)
        else { return }
        input.append(sample)
      }
    }

    public func finish() {
      lock.withLock { stop() }
    }

    /// A new writer from this keyframe; the old one is cancelled (its last fragment is lost, as at a size change)
    private func start(with frame: EncodedVideoFrame) {
      stop()
      guard let description = EncodedVideoFrame.formatDescription(parameterSets: frame.parameterSets, codec: frame.codec) else { return }
      let writer = AVAssetWriter(contentType: .mpeg4Movie)
      writer.outputFileTypeProfile = .mpeg4AppleHLS
      writer.preferredOutputSegmentInterval = CMTime(seconds: segmentDuration, preferredTimescale: 1000)
      writer.initialSegmentStartTime = CMTime(seconds: frame.time, preferredTimescale: 90_000)
      writer.delegate = self
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { return }
      writer.add(input)
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: CMTime(seconds: frame.time, preferredTimescale: 90_000))
      self.writer = writer
      self.input = input
      formatDescription = description
      parameterSets = frame.parameterSets
    }

    private func stop() {
      guard let writer else { return }
      if writer.status == .writing {
        input?.markAsFinished()
        writer.finishWriting {}
      }
      self.writer = nil
      input = nil
      formatDescription = nil
      parameterSets = []
    }

    public func assetWriter(
      _ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
      segmentReport: AVAssetSegmentReport?
    ) {
      switch segmentType {
      case .initialization:
        onFragment?(MP4Fragment(kind: .initialization, data: segmentData, time: 0, duration: 0))
      case .separable:
        let report = segmentReport?.trackReports.first
        onFragment?(
          MP4Fragment(
            kind: .media, data: segmentData, time: report?.earliestPresentationTimeStamp.seconds ?? 0,
            duration: report?.duration.seconds ?? segmentDuration))
      @unknown default:
        break
      }
    }
  }
#else
  /// Writes encoded frames into fragmented MP4: no writer on this platform yet, so no fragments come.
  public final class FragmentedMP4Writer: @unchecked Sendable {
    public let segmentDuration: Double
    public var onFragment: (@Sendable (MP4Fragment) -> Void)?
    public init(segmentDuration: Double = 1) { self.segmentDuration = segmentDuration }
    public func append(_ frame: EncodedVideoFrame) {}
    public func finish() {}
  }
#endif
