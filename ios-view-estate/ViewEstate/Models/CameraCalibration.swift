import Foundation

/// How far a device has progressed through physical camera QA.
///
/// A device is never called `CALIBRATED` by code: that status is only ever assigned by a person
/// after the standard physical test scenes have been photographed and reviewed.
enum CalibrationStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case untested = "UNTESTED"
    case testing = "TESTING"
    case calibrated = "CALIBRATED"
    case limited = "LIMITED"
    case disabled = "DISABLED"

    var devLabel: String { rawValue }

    /// A disabled device keeps the camera but never brackets.
    var allowsBracketing: Bool { self != .disabled }
}

/// Which physical lens property photography should use on a device.
/// Ultra-wide is never assumed to be better: it is opted into per device after its own test.
enum PreferredLens: String, Codable, Hashable, Sendable, CaseIterable {
    case wide = "WIDE"
    case ultraWide = "ULTRA_WIDE"

    var devLabel: String { rawValue }
}

/// What to do when autofocus does not settle within the strategy's timeout.
enum FocusTimeoutPolicy: String, Codable, Hashable, Sendable {
    /// Lock whatever focus the lens reached and photograph; the capture is flagged.
    case continueWithBestFocus = "CONTINUE_BEST_FOCUS"
    /// Abort before the bracket and ask the person to try again.
    case requireRetry = "REQUIRE_RETRY"
}

struct FocusStrategy: Codable, Hashable, Sendable {
    /// Normalised point of interest (0…1). Centre by default; tap-to-focus will set it later.
    var pointX: Double
    var pointY: Double
    var settleTimeoutMs: Double
    var onTimeout: FocusTimeoutPolicy

    static let centerAutoFocusThenLock = FocusStrategy(
        pointX: 0.5,
        pointY: 0.5,
        settleTimeoutMs: 900,
        onTimeout: .continueWithBestFocus
    )

    var devLabel: String {
        String(format: "AF@(%.2f,%.2f) → LOCK · %.0f ms · %@", pointX, pointY, settleTimeoutMs, onTimeout.rawValue)
    }
}

struct WhiteBalanceStrategy: Codable, Hashable, Sendable {
    var settleTimeoutMs: Double
    /// Largest per-channel gain drift, relative, tolerated between frames of one bracket.
    var maxGainVariation: Double
    /// Largest colour-temperature span, in kelvin, tolerated between frames of one bracket.
    var maxTemperatureVariationK: Double

    static let autoSettleThenLock = WhiteBalanceStrategy(
        settleTimeoutMs: 700,
        maxGainVariation: 0.04,
        maxTemperatureVariationK: 150
    )

    var devLabel: String {
        String(format: "AWB → LOCK · %.0f ms · Δgain %.0f%% · Δ%.0f K", settleTimeoutMs, maxGainVariation * 100, maxTemperatureVariationK)
    }
}

/// How the EV 0 reference is metered. Predictable, never re-metered mid-bracket.
enum MeteringStrategy: String, Codable, Hashable, Sendable {
    /// Continuous auto exposure with its point of interest at the composition centre.
    case centerWeighted = "CENTER_WEIGHTED"
}

struct ExposureStrategy: Codable, Hashable, Sendable {
    var metering: MeteringStrategy
    var settleTimeoutMs: Double

    static let centerWeighted = ExposureStrategy(metering: .centerWeighted, settleTimeoutMs: 900)
}

/// Every number that decides "stable". Experimental values, adjustable without touching the UI.
///
/// Variances are second moments of the gravity-free signal over the rolling window, i.e. the mean
/// squared rotation rate (rad/s)² and the mean squared user acceleration (g²): a phone at rest
/// sits near zero on both.
struct StabilityThresholds: Codable, Hashable, Sendable {
    var stabilityWindowMs: Double
    var minimumStableDurationMs: Double
    var maxRotationVariance: Double
    var maxAccelerationVariance: Double
    /// Instantaneous peaks that make the shutter wait, when `blockCaptureWhenSevere` is on.
    var severeRotationRate: Double
    var severeAcceleration: Double
    var blockCaptureWhenSevere: Bool
    /// Mean stability during a bracket below this flags `MOTION_WARNING`…
    var motionWarningScore: Double
    /// …and below this, `MOTION_SEVERE`.
    var motionSevereScore: Double

    static let `default` = StabilityThresholds(
        stabilityWindowMs: 500,
        minimumStableDurationMs: 350,
        maxRotationVariance: 0.0036,
        maxAccelerationVariance: 0.0009,
        severeRotationRate: 1.4,
        severeAcceleration: 0.45,
        blockCaptureWhenSevere: true,
        motionWarningScore: 0.6,
        motionSevereScore: 0.25
    )
}

/// The calibrated capture behaviour of one device (or device family).
///
/// Profiles are configuration values only — never code — so they can later be delivered remotely
/// and adjust the ladder, the lens or the thresholds without an App Store update.
struct CameraCalibrationProfile: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// Hardware identifier (`iPhone16,1`), a family prefix ending in a comma (`iPhone16,`), or `*`.
    var deviceModel: String
    var osVersionRange: OSVersionRange
    /// Optional: pins the profile to one physical camera.
    var cameraUniqueID: String?
    var preferredLens: PreferredLens
    /// Widest standard ladder this device should use. `nil` = widest the hardware supports.
    var captureProfile: CaptureProfile?
    /// Device-specific ladder, in EV, overriding the standard ones when the hardware allows it.
    var exposureValues: [Double]?
    var stabilityThresholds: StabilityThresholds
    var levelToleranceDegrees: Double
    var focusStrategy: FocusStrategy
    var whiteBalanceStrategy: WhiteBalanceStrategy
    var exposureStrategy: ExposureStrategy
    var status: CalibrationStatus
    var profileVersion: Int

    var versionLabel: String { "\(id) v\(profileVersion)" }

    /// The safe default every uncalibrated device starts from.
    static let generic = CameraCalibrationProfile(
        id: "generic",
        deviceModel: "*",
        osVersionRange: OSVersionRange(minimum: "18.0", maximum: nil),
        cameraUniqueID: nil,
        preferredLens: .wide,
        captureProfile: nil,
        exposureValues: nil,
        stabilityThresholds: .default,
        levelToleranceDegrees: 1.5,
        focusStrategy: .centerAutoFocusThenLock,
        whiteBalanceStrategy: .autoSettleThenLock,
        exposureStrategy: .centerWeighted,
        status: .untested,
        profileVersion: 1
    )

    /// How specifically this profile names a device. Higher wins.
    func specificity(deviceModel model: String, cameraUniqueID camera: String?) -> Int? {
        var score: Int
        if deviceModel == "*" {
            score = 0
        } else if deviceModel.hasSuffix(","), model.hasPrefix(deviceModel) {
            score = 1
        } else if deviceModel == model {
            score = 2
        } else {
            return nil
        }
        if let cameraUniqueID {
            guard cameraUniqueID == camera else { return nil }
            score += 10
        }
        return score
    }
}

/// Inclusive iOS version range, compared numerically (`18.10` > `18.2`).
struct OSVersionRange: Codable, Hashable, Sendable {
    var minimum: String
    var maximum: String?

    func contains(_ version: String) -> Bool {
        let value = Self.components(version)
        if Self.compare(value, Self.components(minimum)) < 0 { return false }
        if let maximum, Self.compare(value, Self.components(maximum)) > 0 { return false }
        return true
    }

    var devLabel: String { "\(minimum)…\(maximum ?? "")" }

    private static func components(_ version: String) -> [Int] {
        version
            .replacingOccurrences(of: "iOS", with: "")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - Catalogue & remote foundation

/// The versioned envelope calibration profiles travel in, bundled or remote.
struct CalibrationPayload: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var issuedAt: Date
    var profiles: [CameraCalibrationProfile]
}

/// Resolves the calibration profile for the running device.
///
/// Bundled profiles ship with the app; a remote payload, once validated, takes precedence. Only
/// configuration values are accepted — every number is sanitised into a safe range, and a ladder
/// without EV 0 is discarded — so a remote payload can never make the camera behave unsafely.
enum CameraCalibrationCatalog {
    /// Profiles shipped with the app. Every entry stays `UNTESTED` until physical QA signs it off.
    static let bundled: [CameraCalibrationProfile] = [.generic]

    private static let remoteKey = "ve.camera.calibration.remote"

    /// The most specific profile matching this device, its iOS version and camera.
    static func resolve(
        deviceModel: String,
        systemVersion: String,
        cameraUniqueID: String? = nil,
        profiles: [CameraCalibrationProfile]? = nil
    ) -> CameraCalibrationProfile {
        let candidates = profiles ?? (storedRemoteProfiles() + bundled)
        let ranked = candidates.compactMap { profile -> (Int, CameraCalibrationProfile)? in
            guard profile.osVersionRange.contains(systemVersion),
                  let score = profile.specificity(deviceModel: deviceModel, cameraUniqueID: cameraUniqueID)
            else { return nil }
            return (score, profile)
        }
        // Highest specificity, then highest version; remote entries come first so they win ties.
        let best = ranked.max { lhs, rhs in
            lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.profileVersion < rhs.1.profileVersion
        }
        return best?.1 ?? .generic
    }

    /// Validates and stores a remote payload. Returns the accepted, sanitised profiles.
    ///
    /// - Throws: when the payload is not a supported calibration document.
    @discardableResult
    static func applyRemote(_ data: Data) throws -> [CameraCalibrationProfile] {
        let profiles = try decode(data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stored = try encoder.encode(
            CalibrationPayload(schemaVersion: CalibrationPayload.currentSchemaVersion, issuedAt: .now, profiles: profiles)
        )
        UserDefaults.standard.set(stored, forKey: remoteKey)
        return profiles
    }

    static func clearRemote() {
        UserDefaults.standard.removeObject(forKey: remoteKey)
    }

    static func storedRemoteProfiles() -> [CameraCalibrationProfile] {
        guard let data = UserDefaults.standard.data(forKey: remoteKey) else { return [] }
        return (try? decode(data)) ?? []
    }

    /// Decodes and sanitises a payload without storing it.
    static func decode(_ data: Data) throws -> [CameraCalibrationProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(CalibrationPayload.self, from: data)
        guard payload.schemaVersion == CalibrationPayload.currentSchemaVersion else {
            throw CalibrationPayloadError.unsupportedSchema
        }
        return payload.profiles.map(sanitize)
    }

    /// Clamps every value into a range the camera can safely act on.
    static func sanitize(_ profile: CameraCalibrationProfile) -> CameraCalibrationProfile {
        var safe = profile
        safe.exposureValues = sanitizeLadder(profile.exposureValues)
        safe.levelToleranceDegrees = clamp(profile.levelToleranceDegrees, 0.25, 10)
        safe.profileVersion = max(1, profile.profileVersion)

        var thresholds = profile.stabilityThresholds
        thresholds.stabilityWindowMs = clamp(thresholds.stabilityWindowMs, 150, 3000)
        thresholds.minimumStableDurationMs = clamp(thresholds.minimumStableDurationMs, 0, 3000)
        thresholds.maxRotationVariance = clamp(thresholds.maxRotationVariance, 0.00001, 1)
        thresholds.maxAccelerationVariance = clamp(thresholds.maxAccelerationVariance, 0.00001, 1)
        thresholds.severeRotationRate = clamp(thresholds.severeRotationRate, 0.1, 10)
        thresholds.severeAcceleration = clamp(thresholds.severeAcceleration, 0.05, 4)
        thresholds.motionSevereScore = clamp(thresholds.motionSevereScore, 0, 1)
        thresholds.motionWarningScore = clamp(thresholds.motionWarningScore, thresholds.motionSevereScore, 1)
        safe.stabilityThresholds = thresholds

        safe.focusStrategy.pointX = clamp(profile.focusStrategy.pointX, 0, 1)
        safe.focusStrategy.pointY = clamp(profile.focusStrategy.pointY, 0, 1)
        // Settling must stay short: the camera has to feel immediate.
        safe.focusStrategy.settleTimeoutMs = clamp(profile.focusStrategy.settleTimeoutMs, 100, 2500)
        safe.whiteBalanceStrategy.settleTimeoutMs = clamp(profile.whiteBalanceStrategy.settleTimeoutMs, 100, 2500)
        safe.whiteBalanceStrategy.maxGainVariation = clamp(profile.whiteBalanceStrategy.maxGainVariation, 0.005, 0.5)
        safe.whiteBalanceStrategy.maxTemperatureVariationK = clamp(profile.whiteBalanceStrategy.maxTemperatureVariationK, 20, 2000)
        safe.exposureStrategy.settleTimeoutMs = clamp(profile.exposureStrategy.settleTimeoutMs, 100, 2500)
        return safe
    }

    /// A ladder is kept only when it is sorted, unique, within ±8 EV, at most nine frames and
    /// contains EV 0. Anything else is discarded and the standard profiles apply.
    static func sanitizeLadder(_ values: [Double]?) -> [Double]? {
        guard let values, !values.isEmpty, values.count <= 9 else { return nil }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 8 }) else { return nil }
        let rounded = values.map { ($0 * 100).rounded() / 100 }
        guard rounded.contains(0) else { return nil }
        let ordered = Array(Set(rounded)).sorted()
        guard ordered.count == rounded.count else { return nil }
        return ordered
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(upper, max(lower, value))
    }
}

enum CalibrationPayloadError: Error {
    case unsupportedSchema
}
