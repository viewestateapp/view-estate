import Foundation

/// Sync state of one persisted bracket frame. Local storage always comes first.
enum FrameUploadState: String, Codable, Hashable, Sendable {
    case pendingUpload = "PENDING_UPLOAD"
    case uploading = "UPLOADING"
    case uploaded = "UPLOADED"

    var devLabel: String { rawValue }
}

/// One real photograph of a bracket, exactly as the camera produced it.
///
/// The bytes are never re-encoded, tone mapped or enhanced: this is the source material a future
/// HDR engine will align and merge, so what it records must be what physically happened.
struct CaptureFrame: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var clientFrameID: UUID = UUID()
    /// Assigned once the attempt becomes a capture in the portfolio.
    var captureID: UUID?
    /// The shutter action this frame belongs to. Frames never cross attempts.
    var clientCaptureID: UUID

    /// Deterministic position in the ladder — never inferred from callback order alone.
    var sequenceIndex: Int
    var requestedEV: Double
    /// What the camera actually applied, when it reports it.
    var actualExposureBias: Double?

    var exposureDurationSeconds: Double?
    var iso: Double?
    var aperture: Double?
    var lensPosition: Double?

    var width: Int
    var height: Int
    var exifOrientation: Int
    var orientation: CaptureOrientation

    var cameraID: String
    var lensType: String

    var fileName: String
    var byteCount: Int
    /// SHA-256 of the stored bytes: integrity, duplicate detection and future upload validation.
    var checksum: String

    var capturedAt: Date
    var uploadState: FrameUploadState = .pendingUpload
    var metadata: [String: String] = [:]

    /// The reference frame every future alignment step starts from.
    var isReferenceExposure: Bool { abs(requestedEV) < 0.01 }

    var evLabel: String { CaptureProfile.evLabel(requestedEV) }

    var dimensionDescription: String { "\(width) × \(height)" }

    var sizeDescription: String {
        let megabytes = Double(byteCount) / 1_048_576
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        return "\(max(1, byteCount / 1024)) KB"
    }

    var exposureDescription: String {
        guard let exposureDurationSeconds, exposureDurationSeconds > 0 else { return "—" }
        if exposureDurationSeconds >= 1 { return String(format: "%.2f s", exposureDurationSeconds) }
        return "1/\(Int((1 / exposureDurationSeconds).rounded()))"
    }

    var isoDescription: String {
        guard let iso else { return "—" }
        return "ISO \(Int(iso.rounded()))"
    }

    var apertureDescription: String {
        guard let aperture else { return "—" }
        return String(format: "ƒ/%.1f", aperture)
    }

    var actualBiasDescription: String {
        guard let actualExposureBias else { return "—" }
        return String(format: "%+.2f EV", actualExposureBias)
    }

    /// Reference to this frame's bytes inside the capture bundle.
    var localPhotoFile: LocalPhotoFile {
        LocalPhotoFile(
            fileName: fileName,
            bundleID: clientCaptureID,
            pixelWidth: width,
            pixelHeight: height,
            exifOrientation: exifOrientation,
            orientation: orientation,
            byteCount: byteCount,
            createdAt: capturedAt
        )
    }
}

/// Lifecycle of one capture bundle on disk. Only `localReady` may ever be treated as a capture.
enum CaptureBundleState: String, Codable, Hashable, Sendable {
    case capturing = "CAPTURING"
    case localValidating = "LOCAL_VALIDATING"
    case localReady = "LOCAL_READY"
    case incomplete = "CAPTURE_INCOMPLETE"
    case interrupted = "INTERRUPTED"

    var isValid: Bool { self == .localReady }
    var devLabel: String { rawValue }
}

/// Where a capture's pixels came from, and where its HDR master came from.
/// The distinction is internal: real capture is already true, HDR is still simulated.
enum CaptureSource: String, Codable, Hashable, Sendable {
    case nativeReal = "NATIVE_REAL"
    case simulated = "SIMULATED"

    var devLabel: String { rawValue }
}

enum HDRSource: String, Codable, Hashable, Sendable {
    case mock = "MOCK"
    case real = "REAL"

    var devLabel: String { rawValue }
}

/// The local, self-describing record of one shutter action and everything it produced.
///
/// Written next to the frames themselves, so a capture survives an app restart, needs no
/// connectivity and can be validated without any other source of truth.
struct CaptureManifest: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = CaptureManifest.currentSchemaVersion

    var captureID: UUID?
    var clientCaptureID: UUID

    var organizationID: String
    var propertyID: UUID
    var roomID: String

    var device: String
    var iOSVersion: String
    var appVersion: String

    var cameraID: String
    var lensType: String

    var captureProfile: CaptureProfile
    var expectedFrameCount: Int
    var actualFrameCount: Int
    var segmentCount: Int

    var orientation: CaptureOrientation

    var focusLockSucceeded: LockOutcome
    var whiteBalanceLockSucceeded: LockOutcome

    /// Real pixels, simulated master — kept explicit so nothing downstream can confuse them.
    var captureSource: CaptureSource = .nativeReal
    var hdrSource: HDRSource = .mock

    var state: CaptureBundleState
    /// Normalised reason a bundle is not valid. Never shown to a user.
    var failureCode: String?

    var startedAt: Date
    var completedAt: Date?

    /// Real measurements, in seconds.
    var firstFrameSeconds: Double?
    var bracketSeconds: Double?
    var persistSeconds: Double?
    var manifestSeconds: Double?

    var frames: [CaptureFrame]

    var id: UUID { clientCaptureID }

    var totalByteCount: Int { frames.reduce(0) { $0 + $1.byteCount } }

    var totalSizeDescription: String {
        let megabytes = Double(totalByteCount) / 1_048_576
        return String(format: "%.1f MB", megabytes)
    }

    var orderedFrames: [CaptureFrame] { frames.sorted { $0.sequenceIndex < $1.sequenceIndex } }

    var referenceFrame: CaptureFrame? { frames.first(where: \.isReferenceExposure) }

    var bracketDurationDescription: String {
        guard let bracketSeconds else { return "—" }
        return String(format: "%.2f s", bracketSeconds)
    }

    var frameCountDescription: String { "\(actualFrameCount)/\(expectedFrameCount)" }
}
