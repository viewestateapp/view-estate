import ImageIO
import SwiftUI

/// Renders a capture's photograph through `DisplayAssetResolver`: the verified HDR master once
/// it exists, the EV 0 display preview (or EV 0 original) until then. When the master arrives
/// while the image is on screen, it cross-fades in place — no reload, no navigation change.
///
/// A real capture is never shown with mock pixels. While its file decodes nothing is drawn
/// (the caller's surface shows through); if no real file can be resolved an explicit failure is
/// shown and recorded, never a substitute image. Only simulated captures use bundled imagery.
struct CaptureImage: View {
    let capture: CaptureItem
    var contentMode: ContentMode = .fill
    /// Longest edge to decode. Thumbnails stay small; the viewer asks for more.
    var maxPixel: Int = 640

    @Environment(AppState.self) private var state
    @State private var loaded: LoadedImage?
    @State private var didFail = false

    private struct LoadedImage: Equatable {
        var url: URL
        var image: UIImage
        /// A smaller cached decode shown while the requested size loads.
        var isInterim = false
    }

    private var asset: DisplayedAsset {
        DisplayAssetResolver.resolve(capture, maxPixel: maxPixel)
    }

    var body: some View {
        let asset = self.asset
        ZStack {
            if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .id(loaded.url)
                    .transition(.opacity)
            } else if asset.source == .mock, let name = asset.placeholderName {
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if asset.source == .missing || didFail {
                MissingRealImage(code: DisplayAssetResolver.missingCode)
            }
        }
        .task(id: asset) {
            await load(asset)
        }
    }

    private func load(_ asset: DisplayedAsset) async {
        if let code = DisplayAssetResolver.violation(capture: capture, asset: asset) {
            state.recordMediaIssue(captureID: capture.id, code: code)
        }
        guard let url = asset.url else {
            loaded = nil
            return
        }
        if let loaded, loaded.url == url, !loaded.isInterim { return }

        let size = maxPixel
        let image: UIImage?
        if let cached = CaptureImageLoader.cached(url: url, maxPixel: size) {
            image = cached
        } else {
            // A fast preview beats an empty screen: show the thumbnail-sized decode at once.
            if loaded == nil, size > CaptureImageLoader.thumbnailPixel,
               let low = CaptureImageLoader.cached(url: url, maxPixel: CaptureImageLoader.thumbnailPixel) {
                loaded = LoadedImage(url: url, image: low, isInterim: true)
            }
            image = await Task.detached(priority: .userInitiated) {
                CaptureImageLoader.image(url: url, maxPixel: size)
            }.value
        }
        guard !Task.isCancelled else { return }

        guard let image else {
            // Keep whatever was showing: the photo never disappears. A real capture with nothing
            // to show is an explicit, recorded failure.
            if loaded == nil, capture.isRealCapture {
                didFail = true
                state.recordMediaIssue(captureID: capture.id, code: DisplayAssetResolver.missingCode)
            }
            return
        }
        didFail = false
        let next = LoadedImage(url: url, image: image)
        if loaded == nil || loaded?.url == url {
            loaded = next
        } else {
            // EV 0 → HDR master: a quiet cross-fade, in place.
            withAnimation(.easeInOut(duration: 0.45)) { loaded = next }
        }
    }
}

/// Explicit "no real image" state. Never replaced by demo imagery.
private struct MissingRealImage: View {
    let code: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(VE.textTertiary)
            #if DEBUG
            Text(code)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(VE.warning)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// Downsampled, orientation-correct decoding of stored photographs, with a small memory cache
/// so swiping and returning to a gallery never decode the same file twice.
nonisolated enum CaptureImageLoader {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    /// Decode size used by thumbnails; reused as the viewer's instant first frame.
    static let thumbnailPixel = 640

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    static func cached(url: URL, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func image(url: URL, maxPixel: Int) -> UIImage? {
        if let hit = cached(url: url, maxPixel: maxPixel) { return hit }
        guard let cgImage = cgImage(url: url, maxPixel: maxPixel) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key(url, maxPixel), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Upright pixels (EXIF transform applied), longest edge ≤ `maxPixel`.
    static func cgImage(url: URL, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
