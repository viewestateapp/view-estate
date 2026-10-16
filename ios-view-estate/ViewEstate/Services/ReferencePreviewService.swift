import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Display-sized preview of a capture's EV 0 reference exposure.
///
/// Generated right after the capture is registered, from the EV 0 file only — the rest of the
/// bracket is never decoded to show one photograph. Upright pixels (EXIF orientation applied),
/// written next to the bundle's frames. The original stays byte-for-byte untouched.
nonisolated enum ReferencePreviewService {
    static let fileName = "ev0_preview_v1.jpg"
    /// Long edge in pixels. Viewer requests above this decode the original directly.
    static let maxPixel = 1600

    /// The preview file name when it already exists on disk.
    static func existing(clientCaptureID: UUID) -> String? {
        guard let url = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: fileName),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return fileName
    }

    /// Writes the preview (or returns the existing one). `nil` if the source cannot be read.
    static func generate(clientCaptureID: UUID, source: URL) -> String? {
        if let existing = existing(clientCaptureID: clientCaptureID) { return existing }
        guard let target = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: fileName),
              let image = CaptureImageLoader.cgImage(url: source, maxPixel: maxPixel)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        do {
            try (data as Data).write(to: target, options: .atomic)
            return fileName
        } catch {
            VELog.cameraError("EV0_PREVIEW_WRITE_FAILED", error.localizedDescription)
            return nil
        }
    }
}
