import Foundation

/// Which image a surface shows for a capture.
enum DisplayedAssetType: String, Sendable, Hashable {
    case hdrMaster = "HDR_MASTER"
    case ev0Preview = "EV0_PREVIEW"
    case mockPlaceholder = "MOCK_PLACEHOLDER"
    case none = "NONE"
}

/// Where that image's pixels come from.
enum DisplayedAssetSource: String, Sendable, Hashable {
    case nativeReal = "NATIVE_REAL"
    case viewEstateHDR = "VIEW_ESTATE_HDR"
    case mock = "MOCK"
    case missing = "MISSING"
}

/// The single resolved image for a capture at a given decode size.
struct DisplayedAsset: Sendable, Hashable {
    var type: DisplayedAssetType
    var source: DisplayedAssetSource
    /// Real file on this device. `nil` for mock placeholders or when nothing can be resolved.
    var url: URL?
    /// Bundled demo image name — only ever used for simulated captures.
    var placeholderName: String?
}

/// Resolves the best available image for a capture. Every photo surface uses this — camera
/// thumbnail, galleries, viewer, capture summary — so they can never disagree.
///
/// Priority for a real capture: verified HDR master → EV 0 display preview → EV 0 original.
/// A real capture NEVER resolves to a mock image; if no real file exists the result is
/// `MISSING`, which the interface shows as an explicit failure instead of a substitute.
enum DisplayAssetResolver {
    /// The development assertion raised when a real capture would be shown with mock content.
    static let mockViolationCode = "REAL_CAPTURE_RENDERED_WITH_MOCK_ASSET"
    static let missingCode = "REAL_CAPTURE_IMAGE_MISSING"

    static func resolve(_ capture: CaptureItem, maxPixel: Int) -> DisplayedAsset {
        if let master = capture.hdrMaster, capture.hdrState == .generated {
            let name = maxPixel <= HDRProcessingService.previewMaxPixel ? master.previewFileName : master.fileName
            if let url = CaptureBundleStore.url(clientCaptureID: master.clientCaptureID, fileName: name) {
                return DisplayedAsset(type: .hdrMaster, source: .viewEstateHDR, url: url)
            }
        }

        if capture.isRealCapture {
            if maxPixel <= ReferencePreviewService.maxPixel,
               let name = capture.referencePreviewFileName,
               let url = CaptureBundleStore.url(clientCaptureID: capture.clientCaptureID, fileName: name) {
                return DisplayedAsset(type: .ev0Preview, source: .nativeReal, url: url)
            }
            if let file = capture.localFile, let url = CaptureFileStore.url(for: file) {
                return DisplayedAsset(type: .ev0Preview, source: .nativeReal, url: url)
            }
            return DisplayedAsset(type: .none, source: .missing)
        }

        return DisplayedAsset(type: .mockPlaceholder, source: .mock, placeholderName: capture.image)
    }

    /// `REAL_CAPTURE_RENDERED_WITH_MOCK_ASSET` when a real capture is about to be shown with
    /// mock pixels. Must never happen; surfaced in developer diagnostics if it ever does.
    static func violation(capture: CaptureItem, asset: DisplayedAsset) -> String? {
        guard capture.isRealCapture else { return nil }
        if asset.source == .mock || asset.type == .mockPlaceholder { return mockViolationCode }
        if asset.source == .missing { return missingCode }
        return nil
    }
}

extension CaptureItem {
    /// Real pixels from the native camera. Decided by the evidence (a manifest of real frames
    /// or a stored original), never by the current camera mode.
    var isRealCapture: Bool {
        captureSource == .nativeReal || localFile != nil
    }
}
