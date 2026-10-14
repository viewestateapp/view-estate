import Foundation

/// Where a capture's HDR master stands. Internal only — users see `PreparationStatus`.
nonisolated enum HDRState: String, Codable, Hashable, Sendable {
    /// No real HDR file exists and none will be produced (simulated capture, or the real
    /// pipeline is switched off). Never presented as an HDR master.
    case mock = "MOCK"
    case pending = "PENDING"
    case processing = "PROCESSING"
    /// A real HDR master file exists, was read back and verified.
    case generated = "GENERATED"
    /// The pipeline failed technically. The originals are untouched and a retry is possible.
    case failed = "FAILED"
    /// The bracket itself cannot produce an acceptable HDR (too few real, distinct exposures).
    case sourceRejected = "SOURCE_REJECTED"

    var devLabel: String {
        switch self {
        case .mock: "MOCK / NOT GENERATED"
        case .pending: "REAL_PROCESSING · QUEUED"
        case .processing: "REAL_PROCESSING"
        case .generated: "REAL"
        case .failed: "FAILED"
        case .sourceRejected: "SOURCE_REJECTED"
        }
    }
}

/// Internal stages of one HDR job. Developer diagnostics only.
nonisolated enum HDRStage: String, Codable, Hashable, Sendable {
    case queued = "QUEUED"
    case validating = "VALIDATING"
    case decoding = "DECODING"
    case aligning = "ALIGNING"
    case merging = "MERGING"
    case toneMapping = "TONE_MAPPING"
    case writing = "WRITING"
    case verifying = "VERIFYING"
    case done = "DONE"
    case failed = "FAILED"
}

/// Live record of one HDR job for the developer panel. A job can never stay open forever:
/// the watchdog closes it with `HDR_TIMEOUT`.
nonisolated struct HDRJobDiagnostics: Hashable, Sendable {
    var jobStartedAt: Date
    var stage: HDRStage
    var lastProgressAt: Date
    var finishedAt: Date?
    var errorCode: String?

    var elapsedSeconds: Double {
        (finishedAt ?? .now).timeIntervalSince(jobStartedAt)
    }
}

/// The real, derived HDR master of one capture. The source exposures are never modified;
/// this file lives next to them and points back at its parent capture.
nonisolated struct HDRMasterRecord: Codable, Hashable, Sendable {
    var assetID: UUID
    var captureID: UUID
    var clientCaptureID: UUID
    var fileName: String
    var previewFileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var exifOrientation: Int
    var orientation: CaptureOrientation
    var byteCount: Int
    var previewByteCount: Int
    var checksum: String
    var pipelineVersion: String
    var createdAt: Date

    // Evidence
    var sourceFrameCount: Int
    var distinctExposureLevels: Int
    var referenceFileName: String
    /// Per-frame translation applied to align with EV 0, at master resolution.
    var alignment: [String]
    var processingSeconds: Double
    var ev0HighlightClipPercent: Double
    var ev0ShadowClipPercent: Double
    var hdrHighlightClipPercent: Double
    var hdrShadowClipPercent: Double

    /// Does the master recover detail EV 0 had lost? Measured on the same pixels.
    var dynamicRangeVerdict: String {
        let ev0HasHighlights = ev0HighlightClipPercent >= 0.5
        let ev0HasShadows = ev0ShadowClipPercent >= 0.5
        guard ev0HasHighlights || ev0HasShadows else { return "INCONCLUSIVE · low-contrast scene" }
        let highlights = !ev0HasHighlights || hdrHighlightClipPercent <= ev0HighlightClipPercent * 0.6
        let shadows = !ev0HasShadows || hdrShadowClipPercent <= ev0ShadowClipPercent * 0.6
        return highlights && shadows ? "PASS" : "FAIL"
    }

    var sizeDescription: String {
        String(format: "%.2f MB", Double(byteCount) / 1_048_576)
    }

    var dimensionDescription: String { "\(pixelWidth) × \(pixelHeight)" }

    /// The full-resolution master.
    var masterFile: LocalPhotoFile {
        LocalPhotoFile(
            fileName: fileName,
            bundleID: clientCaptureID,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            exifOrientation: exifOrientation,
            orientation: orientation,
            byteCount: byteCount,
            createdAt: createdAt
        )
    }
}
