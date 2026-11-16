# PlatformMedia

A media player with its video view, and the system's Now Playing controls. Part of [Platform](../README.md).

<!-- platforms: macos ios linux windows=planned android=planned -->

## Purpose

`PlatformMedia` replaces AVFoundation's `AVPlayer` and `AVPlayerLayer` and MediaPlayer's `MPNowPlayingInfoCenter` and
`MPRemoteCommandCenter` with one API an app can use on the Mac, iPhone and Linux: open a file or URL, control playback,
pick audio and subtitle tracks, show the picture in SwiftUI, and take the media keys.

It is not an editor, a transcoder or a capture API (see [PlatformCamera](PlatformCamera.md)), and it has no playlist:
the app keeps its own queue and opens the next file.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformMedia", package: "Platform"),
```

```swift
import PlatformMedia
import SwiftUI

struct PlayerScreen: View {
  let url: URL
  @State private var player = PlatformPlayer()

  var body: some View {
    PlatformVideoView(player: player)
      .task {
        player.onEvent = { event in
          if case .failed(let message) = event { print(message) }
        }
        try? await player.open(url)
        player.play()
      }
  }
}
```

## Main API

### Player

`PlatformPlayer` is a main-actor class. It is not `Observable`: set `onEvent` and read its properties when an event
arrives.

- `open(_:) async throws`: opens a file or a network URL the engine can read and returns once it's ready, paused on
  its first picture. Throws `PlatformPlayerError` when it can't be played. Opening another file cancels this one.
- `play()`, `pause()`, `seek(to:exact:)`, `stop()` (closes the media).
- `state`: a `PlatformPlayerState` (`.idle`, `.loading`, `.ready`, `.playing`, `.paused`, `.ended`, `.failed`);
  `isPlaying`; `errorMessage`.
- `url`, `position` (seconds), `duration`, `videoSize`.
- `volume` (0...1), `isMuted`, `rate`.
- `tracks`, `videoTracks`, `audioTracks`, `subtitleTracks` (`PlatformMediaTrack`: `id`, `kind`, `codec`, `language`,
  `title`, `channelCount`, `sampleRate`, `isDefault`); `audioTrackID`, `subtitleTrackID`;
  `selectAudioTrack(_:)`, `selectSubtitleTrack(_:)` (nil turns subtitles off).
- `timeInterval`: how often `.time` events come while playing (default 0.25 s).
- `onEvent`: called on the main actor with a `PlatformPlayerEvent`: `.state`, `.time`, `.media` (duration or tracks
  changed), `.videoSize`, `.ended`, `.failed(String)`.
- `PlatformPlayer.engineName` ("AVFoundation", "GStreamer") and `engineVersion`.

### Video view

- `PlatformVideoView(player:)`: a SwiftUI view showing the player's picture, fitted, on black.

### Now Playing

- `NowPlaying(name:handler:)`: makes the app the system's Now Playing app. `handler` gets each `NowPlaying.Command`
  (`.play`, `.pause`, `.togglePlayPause`, `.nextTrack`, `.previousTrack`) on the main actor and returns whether it
  could run it. `name` names the player to the desktop.
- `update(_:)`: what plays now (`NowPlaying.Item`: `title`, `duration`, `position`, `isPlaying`), or `nil` when
  nothing does.

## Backends

| | Player and view | Now Playing |
|---|---|---|
| macOS, iOS / iPadOS | AVFoundation: `AVPlayer`, shown on an `AVPlayerLayer` | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` |
| Linux | GStreamer's `playbin`; an appsink hands BGRx frames to the view as images | an MPRIS server on the session bus (`org.mpris.MediaPlayer2.<name>.instance<pid>`) through GIO |
| Windows, Android | none | none |

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: builds against system libraries declared in `Package.swift`:
  `apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev`. At run time playback needs
  `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad` and `gstreamer1.0-libav` for the codecs. A desktop without a
  session bus doesn't see Now Playing; nothing fails. The video view comes from v57/SwiftUI on Linux (GitHub's `main`,
  or `../SwiftUI` with `V57_LOCAL=1`).
- **Windows, Android**: no player engine yet. `PlatformPlayer` has no engine to compile against there, so the library
  doesn't build on those platforms yet.

## Testing

```bash
swift test --filter PlatformMediaTests
PLATFORM_MEDIA_TEST_FILE=~/Movies/sample.mp4 swift test --filter PlatformMediaTests
```

Without `PLATFORM_MEDIA_TEST_FILE` only the failure test runs (a file that can't be played). With it, the test opens
the file, checks its length and video track, and plays it muted for a moment.

## Related

- [SwiftUI](../../SwiftUI/docs/SwiftUI.md): `PlatformVideoView` off Apple platforms (Linux).
- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
