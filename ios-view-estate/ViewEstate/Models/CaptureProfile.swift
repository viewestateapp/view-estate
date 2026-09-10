import Foundation

/// The exposure ladders View Estate is allowed to photograph.
///
/// This is the ONLY place a bracket sequence is defined — no component, service or view may
/// declare its own array of exposure values. Every bracket profile contains EV 0, the reference
/// frame future alignment, geometry and HDR merge depend on.
enum CaptureProfile: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case full9 = "FULL_9"
    case standard7 = "STANDARD_7"
    case compact5 = "COMPACT_5"
    case basic3 = "BASIC_3"
    case single = "SINGLE"

    var id: String { rawValue }

    /// Developer-panel label only.
    var devLabel: String { rawValue }

    var exposureValues: [Int] {
        switch self {
        case .full9: [-4, -3, -2, -1, 0, 1, 2, 3, 4]
        case .standard7: [-3, -2, -1, 0, 1, 2, 3]
        case .compact5: [-2, -1, 0, 1, 2]
        case .basic3: [-2, 0, 2]
        case .single: [0]
        }
    }

    var expectedFrameCount: Int { exposureValues.count }

    var isBracket: Bool { self != .single }

    var minimumEV: Int { exposureValues.min() ?? 0 }
    var maximumEV: Int { exposureValues.max() ?? 0 }

    /// EV 0 is mandatory. A bracket without it is never accepted.
    var includesReferenceExposure: Bool { exposureValues.contains(0) }

    /// Preferred first. Selection walks this order and stops at the first safely supported entry.
    static let preferenceOrder: [CaptureProfile] = [.full9, .standard7, .compact5, .basic3, .single]

    /// The next profile to try when this one is not safely supported.
    var nextFallback: CaptureProfile? {
        guard let index = Self.preferenceOrder.firstIndex(of: self),
              index + 1 < Self.preferenceOrder.count
        else { return nil }
        return Self.preferenceOrder[index + 1]
    }

    /// `-4`, `0`, `+4` — used in file names and the developer frame inspector.
    static func evLabel(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let whole = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", abs(rounded))
        if rounded > 0 { return "+\(whole.replacingOccurrences(of: "-", with: ""))" }
        return whole
    }
}

/// Whether a hardware lock was actually obtained. Never claimed optimistically.
enum LockOutcome: String, Codable, Hashable, Sendable {
    case succeeded = "YES"
    case failed = "NO"
    case unsupported = "UNSUPPORTED"

    var devLabel: String { rawValue }
}

/// What the real active camera reports before a bracket is planned.
///
/// Nothing here is assumed: every value is read from the device and its photo output, because
/// exposure range and bracket size differ between iPhone models, lenses and active formats.
struct CameraExposureCapabilities: Codable, Hashable, Sendable {
    var deviceModel: String
    var systemVersion: String
    var activeLens: String
    var cameraID: String
    var activeFormat: String
    var minExposureBias: Double
    var maxExposureBias: Double
    var maxBracketCount: Int
    var supportsBracketCapture: Bool
    var supportsExposureLock: Bool
    var supportsCustomExposure: Bool
    var supportsFocusLock: Bool
    var supportsWhiteBalanceLock: Bool
    var supportsLensStabilization: Bool

    var minExposureBiasDescription: String { String(format: "%.1f EV", minExposureBias) }
    var maxExposureBiasDescription: String { String(format: "%+.1f EV", maxExposureBias) }

    /// Reported when no camera could be inspected (for example on a simulator with no device).
    static let unavailable = CameraExposureCapabilities(
        deviceModel: "—",
        systemVersion: "—",
        activeLens: "—",
        cameraID: "—",
        activeFormat: "—",
        minExposureBias: 0,
        maxExposureBias: 0,
        maxBracketCount: 0,
        supportsBracketCapture: false,
        supportsExposureLock: false,
        supportsCustomExposure: false,
        supportsFocusLock: false,
        supportsWhiteBalanceLock: false,
        supportsLensStabilization: false
    )
}

/// The concrete sequence one shutter action will photograph.
///
/// A device that cannot deliver the whole ladder in a single native bracket request still keeps
/// the profile: the ladder is split into consecutive native bracket requests taken back to back
/// with focus, white balance and the exposure reference held for the entire attempt.
struct BracketPlan: Codable, Hashable, Sendable {
    var profile: CaptureProfile
    var segments: [[Int]]
    /// Why this profile was chosen. Developer panel only.
    var reason: String

    var exposureValues: [Int] { segments.flatMap { $0 } }
    var expectedFrameCount: Int { exposureValues.count }
    var isSegmented: Bool { segments.count > 1 }

    var segmentDescription: String {
        isSegmented ? "\(segments.count) × \(segments.first?.count ?? 0)" : "1 × \(expectedFrameCount)"
    }

    static let single = BracketPlan(
        profile: .single,
        segments: [[0]],
        reason: "Bracket capture unavailable on this camera."
    )
}
