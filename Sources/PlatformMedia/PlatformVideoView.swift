import SwiftUI

/// The picture of a `PlatformPlayer`, fitted in the view on black (letterboxed). An AVPlayerLayer on Apple
/// platforms; on Linux the frames GStreamer decodes, drawn as images.
public struct PlatformVideoView: View {
  let player: PlatformPlayer

  public init(player: PlatformPlayer) { self.player = player }

  public var body: some View {
    #if canImport(AVFoundation)
      PlayerLayerView(player: player.engine.player).background(Color.black)
    #else
      FrameView(output: player.engine.output)
    #endif
  }
}

#if canImport(AVFoundation)
  import AVFoundation

  #if canImport(AppKit)
    private struct PlayerLayerView: NSViewRepresentable {
      let player: AVPlayer

      func makeNSView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.playerLayer.player = player
        return view
      }

      func updateNSView(_ view: LayerHost, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
      }

      final class LayerHost: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
          super.init(frame: frame)
          wantsLayer = true
          playerLayer.videoGravity = .resizeAspect
          playerLayer.backgroundColor = NSColor.black.cgColor
          layer = playerLayer
        }

        required init?(coder: NSCoder) { nil }
      }
    }
  #elseif canImport(UIKit)
    private struct PlayerLayerView: UIViewRepresentable {
      let player: AVPlayer

      func makeUIView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.playerLayer.player = player
        return view
      }

      func updateUIView(_ view: LayerHost, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
      }

      final class LayerHost: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
          super.init(frame: frame)
          playerLayer.videoGravity = .resizeAspect
          backgroundColor = .black
        }

        required init?(coder: NSCoder) { nil }
      }
    }
  #endif
#else
  /// The newest frame, fitted: only this view re-renders per frame.
  private struct FrameView: View {
    let output: PlatformVideoOutput

    var body: some View {
      ZStack {
        Color.black
        if let frame = output.frame {
          Image(decorative: frame, scale: 1).resizable().aspectRatio(output.aspect, contentMode: .fit)
        }
      }
    }
  }
#endif
