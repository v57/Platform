# PlatformCamera

Capture from the device's cameras, H.264 and HEVC encoding, fragmented MP4, a live video view and motion detection.
Part of [Platform](../README.md).

## Purpose

`PlatformCamera` replaces AVFoundation's capture APIs (`AVCaptureSession`, `AVCaptureMultiCamSession`), VideoToolbox's
compression session, `AVAssetWriter`'s fragmented MP4 output and `AVSampleBufferDisplayLayer` with the pieces a camera
app needs: run one or several cameras at chosen sizes and frame rates, encode their frames in real time, cut the
encoded stream into fragmented MP4 segments, show a live stream, and detect motion. `CameraFeed` describes what a
running camera offers to something that serves it elsewhere, such as a HomeKit accessory server.

It is not a photo API: there is no still capture with RAW, depth or flash, and no recording to a movie file beyond the
fragments.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformCamera", package: "Platform"),
```

```swift
import PlatformCamera

func startCamera() async throws -> (CameraRig, VideoEncoder) {
  guard await CameraCapture.requestAccess(), let device = CameraCapture.defaultDeviceID else {
    throw CameraError.notAuthorized
  }
  let encoder = try VideoEncoder(format: .hd)
  encoder.onFrame = { frame in /* send frame.annexB, or append it to a FragmentedMP4Writer */ }
  let rig = CameraRig()
  rig.onFrame = { _, frame in encoder.encode(frame) }
  try rig.run([CameraConfiguration(device: device, width: 1280, height: 720, fps: 15)])
  return (rig, encoder)
}
```

On iOS and macOS the app's Info.plist needs `NSCameraUsageDescription`, as for any camera code.

## Main API

### Cameras

- `CameraCapture`: `isAvailable`, `access` (`CameraAccess`: `.notDetermined`, `.authorized`, `.denied`),
  `requestAccess() async -> Bool`, `devices()` (`[CameraDevice]`: `id`, `name`, `position` `.front`, `.back` or
  `.external`; the back camera first) and `defaultDeviceID`.
- `CameraRig()`: several cameras at once.
  - `run(_:) throws`: runs exactly these `CameraConfiguration`s (`device`, `width`, `height`, `fps`, `picture`);
    cameras left out stop. Blocks until the sessions are configured. Each camera gets the device format closest above
    its size that reaches its frame rate.
  - `stop()`.
  - `onFrame`: called on the camera's queue for every picture with the device id and a `CameraFrame`.
  - `onInterruption`: capture stopped by itself (camera disconnected, taken by another app, device too hot), with an
    empty reason when it comes back.
  - `onBudget`, `budget`, `estimate(_:)`: the system pressure and what a configuration would cost
    (`CameraBudget`: `hardwareCost`, `systemPressureCost`, `pressure`, `factors`).
  - `lockNow(device:)`: locks focus, exposure and white balance where they are and returns them
    (`CameraLockedValues`).
  - `CameraRig.maximumCameras`, `canRun(together:)`, `capabilities(of:together:)` (`CameraCapabilities`: 16:9
    `sizes` with their highest frame rates, and which adjustments the camera has).
- `CameraPicture`: `stabilization`, and `focus`, `exposure` and `whiteBalance`, each `.auto` (all the time), `.slow`
  (every `CameraPicture.slowInterval`, 10 s, locked in between) or `.locked`.
- `CameraFrame`: `time` (capture clock), `width`, `height`, `lumaGrid(columns:rows:)` (a brightness grid for motion
  detection) and `jpeg(maxWidth:quality:)`.

### Encoding and recording

- `VideoEncoder(format:) throws`: real-time H.264 (Main profile) or HEVC, no B-frames, a keyframe per
  `keyframeInterval`, letterboxed scaling. `encode(_:)` takes a `CameraFrame`; `onFrame` gets each
  `EncodedVideoFrame`. `setBitrate(_:)`, `requestKeyframe()`, `invalidate()`, `VideoEncoder.supports(_:)`.
- `VideoFormat(width:height:fps:bitrate:keyframeInterval:codec:)`, `.hd` (1280x720, 15 fps, 1.5 Mbit/s), `.low`
  (640x360, 15 fps, 400 kbit/s), `suggestedBitrate(width:height:fps:codec:)`. `VideoCodec`: `.h264`, `.hevc`.
- `EncodedVideoFrame`: `data` (AVCC, length-prefixed), `isKeyframe`, `time`, `duration`, `parameterSets` (SPS and
  PPS, plus the VPS for HEVC), `width`, `height`, `nalUnits`, `annexB` (start codes, parameter sets before a keyframe).
- `FragmentedMP4Writer(segmentDuration:)`: `append(_:)` encoded frames as they are (no re-encoding), `finish()`;
  `onFragment` gets an `MP4Fragment` of kind `.initialization` (`ftyp` + `moov`, first and again when the picture size
  changes) or `.media` (`moof` + `mdat`, one segment from a keyframe).

### Showing a stream

- `CameraVideoRenderer()`: `enqueue(_:)` encoded frames from any thread, `reset()`.
- `CameraVideoView(renderer:)`: the SwiftUI view showing the renderer's frames as they arrive, without buffering.
  SwiftUI overlays draw over the video.

### Motion

- `MotionDetector(sensitivity:cooldown:framesToStart:zone:)`: frame differencing against a slowly updated background.
  `process(luma:columns:time:)` takes each frame's `lumaGrid` and returns a `MotionEvent` (`isActive`, `level`,
  `date`) when motion starts or ends. A change of most of the picture at once (lights, exposure) becomes the new
  background. With a `zone` (`MotionDetector.Zone`, 0...1, origin top left) only cells inside it count; `box` is the
  changed cells' bounding box. `reset()`.

### Serving a camera

- `CameraFeed` (protocol): `supportedFormats`, `video(_:) -> CameraVideoStream`, `snapshot(maxWidth:)`,
  `motionEvents()`, `recording(prebuffer:) -> AsyncStream<MP4Fragment>`. The app implements it on top of the pieces
  above.
- `CameraVideoStream`: `format`, `frames`, `setBitrate(_:)`, `requestKeyframe()`, `stop()`.

`CameraError`: `.unavailable` (no backend on this platform), `.notAuthorized`, `.noDevice`, `.failed(String)`.

## Backends

- **macOS**: one `AVCaptureSession` per camera, VideoToolbox, `AVAssetWriter` with the HLS profile,
  `AVSampleBufferDisplayLayer` (the view's host is layer-backed).
- **iOS / iPadOS**: one session that becomes an `AVCaptureMultiCamSession` past one camera; the same encoder, writer
  and view.
- **Linux, Windows, Android**: none yet. The types build; `CameraCapture.isAvailable` is false and `devices()` empty,
  `CameraRig.run` and `VideoEncoder(format:)` throw `CameraError.unavailable`, the writer and renderer do nothing.
  `MotionDetector` and the value types are plain Swift and work everywhere.

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: builds without capture or encoding.
- **Windows, Android**: no backend yet.

## Testing

```bash
swift test --filter PlatformCameraTests
```

The tests cover motion detection (zones and the changed box) and, on Apple platforms, H.264 and HEVC encoding of
generated frames; no camera is needed.
