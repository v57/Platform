import SwiftUI

/// Shows a live H.264 stream frame by frame as it arrives, without buffering: `enqueue` the frames, put a
/// `CameraVideoView` on screen. AVSampleBufferDisplayLayer on Apple platforms; nothing on Linux yet.
public final class CameraVideoRenderer: @unchecked Sendable {
  #if canImport(AVFoundation)
    let layer: AVSampleBufferDisplayLayer
    /// The layer's renderer, which takes frames on any thread
    private let output: AVSampleBufferVideoRenderer

    @MainActor public init() {
      layer = AVSampleBufferDisplayLayer()
      output = layer.sampleBufferRenderer
    }

    private let lock = NSLock()
    private var description: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var waitsForKeyframe = true

    /// Shows `frame` now; frames before the first keyframe (and after an error, until the next one) are skipped
    public func enqueue(_ frame: EncodedVideoFrame) {
      let sample: CMSampleBuffer? = lock.withLock {
        if frame.isKeyframe, frame.parameterSets != parameterSets {
          description = EncodedVideoFrame.formatDescription(parameterSets: frame.parameterSets)
          parameterSets = frame.parameterSets
        }
        if frame.isKeyframe { waitsForKeyframe = false }
        guard !waitsForKeyframe, let description else { return nil }
        return frame.sampleBuffer(description: description, displayImmediately: true)
      }
      guard let sample else { return }
      if output.status == .failed {
        output.flush()
        lock.withLock { waitsForKeyframe = true }
        return
      }
      output.enqueue(sample)
    }

    /// Clears the picture, for another stream
    public func reset() {
      lock.withLock {
        description = nil
        parameterSets = []
        waitsForKeyframe = true
      }
      output.flush(removingDisplayedImage: true, completionHandler: nil)
    }
  #else
    public init() {}
    public func enqueue(_ frame: EncodedVideoFrame) {}
    public func reset() {}
  #endif
}

/// The picture of a `CameraVideoRenderer`, fitted in the view on black.
public struct CameraVideoView: View {
  let renderer: CameraVideoRenderer

  public init(renderer: CameraVideoRenderer) { self.renderer = renderer }

  public var body: some View {
    #if canImport(AVFoundation)
      LayerView(layer: renderer.layer).background(Color.black)
    #else
      Color.black.overlay(Text("Live video isn’t supported on this platform yet.").foregroundStyle(.white))
    #endif
  }
}

#if canImport(AVFoundation)
  import AVFoundation

  #if canImport(AppKit)
    private struct LayerView: NSViewRepresentable {
      let layer: AVSampleBufferDisplayLayer

      func makeNSView(context: Context) -> Host { Host(layer: layer) }
      func updateNSView(_ view: Host, context: Context) {}

      final class Host: NSView {
        init(layer displayLayer: AVSampleBufferDisplayLayer) {
          super.init(frame: .zero)
          wantsLayer = true
          displayLayer.videoGravity = .resizeAspect
          displayLayer.backgroundColor = NSColor.black.cgColor
          layer = displayLayer
        }

        required init?(coder: NSCoder) { nil }
      }
    }
  #elseif canImport(UIKit)
    private struct LayerView: UIViewRepresentable {
      let layer: AVSampleBufferDisplayLayer

      func makeUIView(context: Context) -> Host { Host(layer: layer) }
      func updateUIView(_ view: Host, context: Context) {}

      final class Host: UIView {
        let displayLayer: AVSampleBufferDisplayLayer

        init(layer: AVSampleBufferDisplayLayer) {
          displayLayer = layer
          super.init(frame: .zero)
          backgroundColor = .black
          layer.videoGravity = .resizeAspect
          self.layer.addSublayer(layer)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
          super.layoutSubviews()
          displayLayer.frame = bounds
        }
      }
    }
  #endif
#endif
