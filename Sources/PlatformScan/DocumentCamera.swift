import SwiftUI

#if canImport(VisionKit) && os(iOS)
  import VisionKit
#endif

/// The system's document camera: it finds the page's edges, takes it when it holds still, straightens it, and lets
/// the user retake or add pages. VisionKit on iPhone and iPad; elsewhere `isAvailable` is false (the Mac takes pages
/// from an iPhone with Continuity Camera's Scan Documents instead, through SwiftUI's `importsItemProviders`).
///
/// ```swift
/// .sheet(isPresented: $scanning) {
///   DocumentCamera { pages in add(pages) } cancel: { scanning = false }.ignoresSafeArea()
/// }
/// ```
public struct DocumentCamera: View {
  /// The pages taken, as JPEG, in order.
  let finish: @MainActor ([PageImage]) -> Void
  let cancel: @MainActor () -> Void
  let quality: Double

  public init(
    quality: Double = 0.8, finish: @escaping @MainActor ([PageImage]) -> Void, cancel: @escaping @MainActor () -> Void
  ) {
    self.quality = quality
    self.finish = finish
    self.cancel = cancel
  }

  public static var isAvailable: Bool {
    #if canImport(VisionKit) && os(iOS)
      VNDocumentCameraViewController.isSupported
    #else
      false
    #endif
  }

  public var body: some View {
    #if canImport(VisionKit) && os(iOS)
      Camera(finish: finish, cancel: cancel, quality: quality)
    #else
      Text("This device has no document camera.")
        .foregroundStyle(.secondary)
        .padding()
    #endif
  }
}

#if canImport(VisionKit) && os(iOS)
  private struct Camera: UIViewControllerRepresentable {
    let finish: @MainActor ([PageImage]) -> Void
    let cancel: @MainActor () -> Void
    let quality: Double

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
      let controller = VNDocumentCameraViewController()
      controller.delegate = context.coordinator
      return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
      context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
      var parent: Camera

      init(parent: Camera) { self.parent = parent }

      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
      ) {
        let pages = (0..<scan.pageCount).compactMap { index -> PageImage? in
          let image = scan.imageOfPage(at: index)
          guard let cgImage = image.cgImage, let data = image.jpegData(compressionQuality: parent.quality) else {
            return nil
          }
          return PageImage(data: data, width: cgImage.width, height: cgImage.height)
        }
        parent.finish(pages)
      }

      func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.cancel() }

      func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        parent.cancel()
      }
    }
  }
#endif
