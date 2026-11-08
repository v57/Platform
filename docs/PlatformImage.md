# PlatformImage

Image files without the platform's image types: their pixel size, their pictures scaled down, and pictures written as
PNG or JPEG. Part of [Platform](../README.md).

## Purpose

`PlatformImage` replaces ImageIO (`CGImageSource`, `CGImageDestination`) for the common jobs: a thumbnail for a list,
an image's size, the full picture, and writing a picture the app drew. Pictures come back as a `Bitmap` of RGBA bytes,
which every UI layer can show, instead of `CGImage`, `NSImage` or `UIImage`.

It is not an editor or a filter pipeline: there is no cropping, color management or format conversion beyond writing
PNG and JPEG.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformImage", package: "Platform"),
```

```swift
import Foundation
import PlatformImage

func makeThumbnail(of photo: URL, to output: URL) throws {
  guard let picture = ImageFile.thumbnail(at: photo, maxPixel: 600) else { return }
  try ImageFile.write(picture, to: output, format: .jpeg(quality: 0.8))
}
```

## Main API

- `ImageFile.pixelSize(at:)`: the image's width and height in pixels, nil when it can't be read.
- `ImageFile.thumbnail(at:maxPixel:)`: the picture scaled so its longer side is at most `maxPixel`, as a `Bitmap`.
- `ImageFile.load(at:)`: the whole picture at its own size.
- `ImageFile.write(_:to:format:) throws`: writes a `Bitmap` as `.png` or `.jpeg(quality:)` (0...1), replacing what's
  there. Throws `ImageFileError` when the bitmap has no pixels or the file can't be written.
- `Bitmap(width:height:rgba:)`: RGBA, 8 bits a channel, premultiplied by alpha, sRGB, rows top to bottom with no
  padding (what a `CGImage` with `premultipliedLast` takes as it is); `bytesPerRow`.

Formats read: PNG, JPEG, HEIC on Apple platforms, and WebP where the system reads it.

## Backends

- **macOS, iOS**: ImageIO.
- **Linux**: GdkPixbuf (`apt install libgdk-pixbuf-2.0-dev`; GTK desktops have the run-time library). Writing goes
  through GdkPixbuf's `savev`.
- **Windows, Android**: none. Reads return nil and `write` throws.

## Platform notes

- **macOS, iOS**: supported.
- **Linux**: reading builds on the Ubuntu VM. The Linux path of `write` was committed without a VM build: check it
  before relying on it.
- **Windows, Android**: no backend yet.

## Testing

```bash
swift test --filter PlatformImageTests
```
