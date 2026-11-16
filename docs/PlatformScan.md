# PlatformScan

Pages read on the device: their text, the page's corners, the page straightened and cleaned up, an imported PDF's
pages, a redacted and watermarked copy, and the document camera. Part of [Platform](../README.md).

<!-- platforms: macos=partial ios linux=planned windows=planned android=planned -->

## Purpose

`PlatformScan` replaces Vision's text recognition and document segmentation, Core Image's perspective correction and
document filter, PDFKit, and VisionKit's `VNDocumentCameraViewController` with one API for apps that keep scanned
documents. Everything happens on the device; nothing leaves it.

It is not a general computer-vision library: no barcodes, faces or image classification.

## Getting started

```swift
.package(url: "https://github.com/v57/Platform.git", branch: "main"),
// target dependency:
.product(name: "PlatformScan", package: "Platform"),
```

```swift
import Foundation
import PlatformScan

func scan(_ photo: Data) async throws -> (page: PageImage, lines: [PageTextLine]) {
  guard PageScanner.isAvailable else { throw ScanError("this system can't read pages yet") }
  let quad = try await PageScanner.edges(in: photo) ?? .full
  let page = try PageScanner.straighten(photo, quad: quad, look: .document)
  let lines = try await PageScanner.lines(in: page.data)
  return (page, lines)
}
```

Images go in and come out as encoded data (JPEG, PNG, HEIC); results are `PageImage`s (JPEG `data`, `width`,
`height`, `contentType`). Geometry is in parts of the picture (0...1, origin top left): `PagePoint`, `PageRect`,
`PageQuad` (`.full` is the whole picture).

## Main API

### PageScanner

- `isAvailable`.
- `lines(in:) async throws -> [PageTextLine]`: the page's lines in reading order (`text`, `box`, `confidence`).
  Language correction is off, and pieces of one printed line come back as one line while columns stay apart.
- `text(in:) async throws -> [String]`: the text of each line.
- `edges(in:) async throws -> PageQuad?`: where the page's corners are in a photo, nil when no page stands out.
- `straighten(_:quad:look:maxPixel:quality:) throws -> PageImage`: the page inside `quad` as a flat rectangle, in a
  `PageLook` (`.color`, `.grayscale`, `.document`: white paper and dark ink, shadows lifted).
- `thumbnail(of:maxPixel:quality:)`, `pixelSize(of:)` (orientation applied).
- `page(from:quality:)` (Apple platforms only): a `CGImage` the app drew, as a JPEG page.

The first text request in an app can take many seconds while the system prepares its model; requests run on a queue
of their own, not Swift's cooperative pool.

### PDFPages

- `isAvailable`, `isPDF(_:)`, `pageCount(_:)` (nil when it isn't a PDF this system opens, or it's locked),
  `text(_:)` (each page's text layer), `pageSize(_:page:)` (points, rotation applied),
  `render(_:page:maxPixel:quality:)` (a page drawn on white, as JPEG).

### PageCopy

- `PageCopy.pdf(_:watermark:title:maxPixel:quality:) throws -> Data`: a PDF to give someone, each page as wide as A4.
  Each `PageCopy.Page` (`image`, `hidden: [PageRect]`) has its hidden parts blacked out and the watermark drawn into
  the picture itself, so nothing lies under a black box and the watermark can't be lifted off. The copy has no text
  layer. `PageCopy.isAvailable`.

### DocumentCamera

- `DocumentCamera(quality:finish:cancel:)`: a SwiftUI view showing the system's document camera, which finds the
  page's edges, takes it when it holds still, straightens it and lets the user retake or add pages. `finish` gets the
  pages as JPEG `PageImage`s, in order. `DocumentCamera.isAvailable`.

`ScanError(_:)` carries a description; calls on a platform without a reader throw one that says so.

## Backends

- **macOS, iOS / iPadOS**: Vision (text, document segmentation and rectangles), Core Image (`CIPerspectiveCorrection`
  and the document filter), PDFKit, Core Graphics and Core Text for copies.
- **DocumentCamera**: VisionKit on iPhone and iPad only. On the Mac `isAvailable` is false; Continuity Camera's Scan
  Documents (through SwiftUI's `importsItemProviders`) takes its place.
- **Linux, Windows, Android**: none yet. Each `isAvailable` is false, `PageScanner` calls throw, `PDFPages` and
  thumbnails return nil, and `PageCopy.pdf` throws.

## Platform notes

- **iOS**: supported.
- **macOS**: everything except `DocumentCamera`, whose `isAvailable` is false there.
- **Linux, Windows**: builds; the reading-order code is tested there, and each call says the reader isn't there yet.
- **Android**: not built or tested.

## Testing

```bash
swift test --filter PlatformScanTests
```

On every platform the tests check reading order and line joining. On Apple platforms they also read generated pages,
find and straighten a page, make thumbnails, check that hidden parts are black in the pixels and that the watermark
covers the page, and read a PDF's text and pages.

## Related

- [SwiftUI](../../SwiftUI/docs/SwiftUI.md): `DocumentCamera` off Apple platforms.
- [Platform](../README.md): the library table, one `Platform<Feature>` library per feature.
