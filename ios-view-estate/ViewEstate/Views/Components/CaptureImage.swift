import ImageIO
import SwiftUI

/// Renders a capture's photograph: the real HDR master once it exists, the EV 0 reference
/// exposure while it is still preparing, and the reference image for simulated captures.
/// Layout is identical in every case, so the approved surfaces stay exactly as designed.
///
/// Real photographs are always decoded downsampled (ImageIO thumbnail, EXIF orientation
/// applied) — a 12 MP original is never decoded at full size for a thumbnail or a detail view.
struct CaptureImage: View {
    let capture: CaptureItem
    var contentMode: ContentMode = .fill
    /// Longest edge to decode. Thumbnails stay small; the detail view asks for more.
    var maxPixel: Int = 640

    @State private var localImage: UIImage?

    private var source: URL? {
        if let master = capture.hdrMaster {
            let name = maxPixel <= HDRProcessingService.previewMaxPixel ? master.previewFileName : master.fileName
            return CaptureBundleStore.url(clientCaptureID: master.clientCaptureID, fileName: name)
        }
        return capture.localFile.flatMap { CaptureFileStore.url(for: $0) }
    }

    var body: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(capture.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: source) {
            await load()
        }
    }

    private func load() async {
        guard let url = source else {
            localImage = nil
            return
        }
        let size = maxPixel
        let image = await Task.detached(priority: .userInitiated) {
            CaptureImageLoader.image(url: url, maxPixel: size)
        }.value
        // Keep whatever was showing if the new file cannot be read: the photo never disappears.
        if let image { localImage = image }
    }
}

/// Downsampled, orientation-correct decoding of stored photographs.
nonisolated enum CaptureImageLoader {
    static func image(url: URL, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
