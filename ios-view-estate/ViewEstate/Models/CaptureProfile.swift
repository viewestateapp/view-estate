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

    /// Floating-point EV: calibrated devices may use fractional ladders (±2.5, ±0.5, …).
    var exposureValues: [Double] {
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

    var minimumEV: Double { exposureValues.min() ?? 0 }
    var maximumEV: Double { exposureValues.max() ?? 0 }

    /// EV 0 is mandatory. A bracket without it is never accepted.
    var includesReferenceExposure: Bool { exposureValues.contains { abs($0) < 0.001 } }

    /// The standard profile family a ladder of `count` frames belongs to. A calibrated device
    /// ladder keeps its own values; the family only names it in reports.
    static func family(frameCount count: Int) -> CaptureProfile {
        switch count {
        case 9...: .full9
        case 7...8: .standard7
        case 5...6: .compact5
        case 2...4: .basic3
        default: .single
        }
    }

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
    /// Fractional values keep their sign and up to two decimals (`-2.5`, `+0.25`).
    nonisolated static func evLabel(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        let magnitude = abs(rounded)
        var digits: String
        if magnitude == magnitude.rounded() {
            digits = String(Int(magnitude))
        } else {
            digits = String(format: "%.2f", magnitude)
            while digits.hasSuffix("0") { digits.removeLast() }
        }
        if rounded > 0 { return "+" + digits }
        if rounded < 0 { return "-" + digits }
        return "0"
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
    var segments: [[Double]]
    /// Why this profile was chosen. Developer panel only.
    var reason: String
    var ladderSource: LadderSource = .standardProfile
    /// Calibration profile id and version this plan was derived from.
    var calibrationVersion: String = CameraCalibrationProfile.generic.versionLabel

    var exposureValues: [Double] { segments.flatMap { $0 } }

    var ladderDescription: String {
        exposureValues.map { CaptureProfile.evLabel($0) }.joined(separator: " ")
    }
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
