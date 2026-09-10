import CoreGraphics
import Foundation

/// Which camera implementation the capture flow uses.
///
/// Development can switch at runtime (`camera_native_enabled`), so the simulated viewfinder
/// always stays available as a safe fallback.
enum CameraMode: String, Sendable, CaseIterable, Identifiable {
    case simulated
    case native

    var id: String { rawValue }

    var isNative: Bool { self == .native }

    /// Developer-panel label only.
    var devLabel: String {
        switch self {
        case .simulated: "SIMULATED"
        case .native: "NATIVE"
        }
    }
}

/// Camera authorisation, normalised away from AVFoundation types.
enum CameraAccess: String, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }

    /// Denied and restricted are the two states a user must be helped out of.
    var needsSystemSettings: Bool { self == .denied || self == .restricted }

    var devLabel: String { rawValue.uppercased() }
}

/// Normalised camera failures. A raw AVFoundation error is never shown to a user.
enum CameraError: String, Error, Sendable {
    case permissionDenied = "CAMERA_PERMISSION_DENIED"
    case initializationFailed = "CAMERA_INITIALIZATION_FAILED"
    case captureFailed = "PHOTO_CAPTURE_FAILED"
    case localSaveFailed = "LOCAL_SAVE_FAILED"

    /// Stable code for logs and the developer panel.
    var code: String { rawValue }

    /// User-facing message key. Friendly copy, no technical vocabulary.
    var localizationKey: String {
        switch self {
        case .permissionDenied: "camera.permission.body"
        case .initializationFailed: "camera.error.init"
        case .captureFailed: "camera.error.capture"
        case .localSaveFailed: "camera.error.save"
        }
    }
}

/// Device orientation at the moment of capture, derived from the capture rotation angle.
enum CaptureOrientation: String, Sendable, Codable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// Rotation angles are measured clockwise from landscape-right, the natural sensor position.
    init(videoRotationAngle angle: CGFloat) {
        switch Int(angle.rounded()) % 360 {
        case 90: self = .portrait
        case 180: self = .landscapeLeft
        case 270: self = .portraitUpsideDown
        default: self = .landscapeRight
        }
    }

    var videoRotationAngle: CGFloat {
        switch self {
        case .landscapeRight: 0
        case .portrait: 90
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        }
    }

    var devLabel: String {
        switch self {
        case .portrait: "PORTRAIT"
        case .portraitUpsideDown: "PORTRAIT_UPSIDE_DOWN"
        case .landscapeLeft: "LANDSCAPE_LEFT"
        case .landscapeRight: "LANDSCAPE_RIGHT"
        }
    }
}

/// One original photograph stored inside the application's own container.
///
/// The bytes are exactly what the camera produced — orientation travels as EXIF metadata, so the
/// original is never re-encoded or rotated on disk.
struct LocalPhotoFile: Hashable, Sendable, Codable {
    var fileName: String
    /// Pixel dimensions as recorded by the sensor.
    var pixelWidth: Int
    var pixelHeight: Int
    /// EXIF orientation tag written by the camera (1 = up, 6 = rotated 90° clockwise, …).
    var exifOrientation: Int
    /// Device orientation at the moment of capture.
    var orientation: CaptureOrientation
    var byteCount: Int
    var createdAt: Date

    /// Dimensions as the photograph is displayed once EXIF orientation is applied.
    var displayWidth: Int { isQuarterTurned ? pixelHeight : pixelWidth }
    var displayHeight: Int { isQuarterTurned ? pixelWidth : pixelHeight }

    private var isQuarterTurned: Bool { (5...8).contains(exifOrientation) }

    var pixelDescription: String { "\(pixelWidth) × \(pixelHeight)" }
    var displayDescription: String { "\(displayWidth) × \(displayHeight)" }

    var sizeDescription: String {
        let megabytes = Double(byteCount) / 1_048_576
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        return "\(max(1, byteCount / 1024)) KB"
    }
}

/// Local record of one capture, written next to its photograph so the association between
/// property, room and file survives without any connectivity.
struct CaptureFileRecord: Codable, Sendable {
    var captureID: UUID
    var clientCaptureID: UUID
    var propertyID: UUID
    var roomID: String
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var exifOrientation: Int
    var orientation: CaptureOrientation
    var byteCount: Int
    var createdAt: Date
}

/// What the hardware reported once the session was configured. Developer information only.
struct CameraSetup: Sendable {
    var deviceName: String
    var deviceID: String
    var lens: String
    var captureResolution: String
}

/// Everything the developer panel shows about the camera. Never surfaced to a normal user.
struct CameraDiagnostics: Sendable {
    var mode: CameraMode = .simulated
    var access: CameraAccess = .unknown
    var setup: CameraSetup?
    var lastFile: LocalPhotoFile?
    var lastCaptureSeconds: Double?
    var lastErrorCode: String?

    var captureDurationDescription: String? {
        guard let lastCaptureSeconds else { return nil }
        return String(format: "%.2f s", lastCaptureSeconds)
    }
}
