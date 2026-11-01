import Foundation

#if canImport(VideoToolbox)
  @preconcurrency import VideoToolbox

  /// Encodes captured frames to H.264 for live streaming: real time, no B-frames, Main profile, a keyframe every
  /// `format.keyframeInterval` seconds. Pictures of another size are scaled (letterboxed) to the format's; frames
  /// above the format's frame rate are skipped.
  public final class H264Encoder: @unchecked Sendable {
    public let format: VideoFormat
    /// Called on VideoToolbox's queue, in order, for every encoded frame
    public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var lastTime: Double?
    private var forcesKeyframe = false
    private var parameterSets: [Data] = []

    public init(format: VideoFormat) throws {
      self.format = format
      var session: VTCompressionSession?
      let status = VTCompressionSessionCreate(
        allocator: nil, width: Int32(format.width), height: Int32(format.height), codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
        refcon: nil, compressionSessionOut: &session)
      guard status == noErr, let session else { throw CameraError.failed("The H.264 encoder didn’t start (\(status)).") }
      self.session = session
      let properties: [CFString: Any] = [
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ExpectedFrameRate: format.fps,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: format.keyframeInterval,
        kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int(Double(format.fps) * format.keyframeInterval)),
        kVTCompressionPropertyKey_PixelTransferProperties: [kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Letterbox],
      ]
      for (key, value) in properties {
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
      }
      setBitrate(format.bitrate)
      VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    public func setBitrate(_ bitsPerSecond: Int) {
      guard let session = lock.withLock({ session }) else { return }
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
      // Bursts up to 1.5 times the average within a second
      let limit = [Double(bitsPerSecond) / 8 * 1.5, 1] as CFArray
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    /// The next frame is a keyframe, for a viewer that just joined or lost data
    public func requestKeyframe() {
      lock.withLock { forcesKeyframe = true }
    }

    public func encode(_ frame: CameraFrame) {
      let (session, forced): (VTCompressionSession?, Bool) = lock.withLock {
        // Skips frames that come faster than the format's rate (with a little slack for jitter)
        if let lastTime, frame.time - lastTime < 0.9 / Double(format.fps) { return (nil, false) }
        lastTime = frame.time
        defer { forcesKeyframe = false }
        return (self.session, forcesKeyframe)
      }
      guard let session else { return }
      let options = forced ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
      let pts = CMTime(seconds: frame.time, preferredTimescale: 90_000)
      let duration = CMTime(seconds: 1 / Double(format.fps), preferredTimescale: 90_000)
      VTCompressionSessionEncodeFrame(
        session, imageBuffer: frame.pixelBuffer, presentationTimeStamp: pts, duration: duration, frameProperties: options,
        infoFlagsOut: nil
      ) { [weak self] status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let self else { return }
        if let encoded = self.frame(from: sampleBuffer) { self.onFrame?(encoded) }
      }
    }

    public func invalidate() {
      let session = lock.withLock {
        defer { self.session = nil }
        return self.session
      }
      guard let session else { return }
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(session)
    }

    private func frame(from sampleBuffer: CMSampleBuffer) -> EncodedVideoFrame? {
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
      var length = 0
      var pointer: UnsafeMutablePointer<CChar>?
      guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
        let pointer
      else { return nil }
      let data = Data(bytes: pointer, count: length)
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
      let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
      var parameterSets: [Data] = []
      if isKeyframe, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
        parameterSets = Self.parameterSets(of: description)
      }
      let dimensions = CMSampleBufferGetFormatDescription(sampleBuffer).map(CMVideoFormatDescriptionGetDimensions)
      return EncodedVideoFrame(
        data: data, isKeyframe: isKeyframe, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
        duration: 1 / Double(format.fps), parameterSets: parameterSets,
        width: Int(dimensions?.width ?? Int32(format.width)), height: Int(dimensions?.height ?? Int32(format.height)))
    }

    static func parameterSets(of description: CMFormatDescription) -> [Data] {
      var count = 0
      guard
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
          parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr
      else { return [] }
      return (0..<count).compactMap { index in
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer
        else { return nil }
        return Data(bytes: pointer, count: size)
      }
    }
  }

  extension EncodedVideoFrame {
    /// The H.264 format description of these parameter sets
    static func formatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
      guard parameterSets.count >= 2 else { return nil }
      var description: CMVideoFormatDescription?
      let buffers = parameterSets.map { [UInt8]($0) }
      let status = buffers[0].withUnsafeBufferPointer { sps in
        buffers[1].withUnsafeBufferPointer { pps in
          let pointers = [sps.baseAddress!, pps.baseAddress!]
          let sizes = [sps.count, pps.count]
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
      }
      return status == noErr ? description : nil
    }

    /// A sample buffer of this frame in `description`'s format, for a decoder, a display layer or a file writer
    func sampleBuffer(description: CMVideoFormatDescription, displayImmediately: Bool = false) -> CMSampleBuffer? {
      var block: CMBlockBuffer?
      guard
        CMBlockBufferCreateWithMemoryBlock(
          allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
          offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
        let block
      else { return nil }
      let copied = data.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
      }
      guard copied == noErr else { return nil }
      var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: duration, preferredTimescale: 90_000),
        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
      var size = data.count
      var sample: CMSampleBuffer?
      guard
        CMSampleBufferCreateReady(
          allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1,
          sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
        let sample
      else { return nil }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        if !isKeyframe {
          CFDictionarySetValue(
            dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayImmediately {
          CFDictionarySetValue(
            dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
      }
      return sample
    }
  }
#else
  /// Encodes captured frames to H.264: no encoder on this platform yet, so `init` throws `CameraError.unavailable`.
  public final class H264Encoder: @unchecked Sendable {
    public let format: VideoFormat
    public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?
    public init(format: VideoFormat) throws { throw CameraError.unavailable }
    public func setBitrate(_ bitsPerSecond: Int) {}
    public func requestKeyframe() {}
    public func encode(_ frame: CameraFrame) {}
    public func invalidate() {}
  }
#endif
