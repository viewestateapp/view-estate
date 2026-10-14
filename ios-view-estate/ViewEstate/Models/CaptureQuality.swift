import Foundation

// MARK: - Stability

/// Internal stability state. The person only ever sees "Estável", "A estabilizar" or
/// "Mantenha estável" — never a number.
enum StabilityState: String, Codable, Hashable, Sendable {
    case unstable = "UNSTABLE"
    case stabilizing = "STABILIZING"
    case stable = "STABLE"

    var devLabel: String { rawValue }

    var localizationKey: String {
        switch self {
        case .unstable: "camera.hold.steady"
        case .stabilizing: "camera.stabilizing"
        case .stable: "camera.stable"
        }
    }
}

/// How much the phone moved while a bracket was being photographed.
enum MotionAssessment: String, Codable, Hashable, Sendable {
    case none = "NONE"
    case warning = "MOTION_WARNING"
    case severe = "MOTION_SEVERE"
    /// No motion sensor (simulator, restricted device): nothing can be claimed either way.
    case unavailable = "SENSOR_UNAVAILABLE"

    var devLabel: String { rawValue }
}

/// Motion recorded around one shutter action: before, during and at the end of the bracket.
/// Future HDR alignment and deghosting will read these values.
struct CaptureMotionSnapshot: Codable, Hashable, Sendable {
    var sensorAvailable: Bool
    var stabilityBeforeCapture: Double?
    var stateBeforeCapture: StabilityState?
    /// Mean stability score over the whole bracket.
    var stabilityDuringCapture: Double?
    var minimumStabilityDuringCapture: Double?
    var stabilityAtEnd: Double?
    /// Peak instantaneous rotation rate, rad/s.
    var maxRotationDuringCapture: Double?
    /// Peak instantaneous user acceleration, g.
    var maxAccelerationDuringCapture: Double?
    /// Horizon tilt and camera tilt frozen at the shutter tap, in degrees.
    var rollAngleAtCapture: Double?
    var pitchAngleAtCapture: Double?
    var wasLevelAtCapture: Bool?
    var sampleCount: Int
    var assessment: MotionAssessment

    /// The single score stored with the capture attempt.
    var stabilityScore: Double? { stabilityDuringCapture ?? stabilityBeforeCapture }

    static let unavailable = CaptureMotionSnapshot(
        sensorAvailable: false,
        sampleCount: 0,
        assessment: .unavailable
    )
}

// MARK: - Focus & white balance

/// Internal focus state across one attempt. Never surfaced to a normal user.
enum FocusStatus: String, Codable, Hashable, Sendable {
    case searching = "FOCUS_SEARCHING"
    case ready = "FOCUS_READY"
    case locked = "FOCUS_LOCKED"
    case unavailable = "FOCUS_UNAVAILABLE"
    case failed = "FOCUS_FAILED"

    var devLabel: String { rawValue }
}

/// White balance as the camera reported it: raw device gains plus the derived temperature/tint.
struct WhiteBalanceReading: Codable, Hashable, Sendable {
    var redGain: Double
    var greenGain: Double
    var blueGain: Double
    var temperature: Double?
    var tint: Double?

    var devLabel: String {
        let gains = String(format: "R%.3f G%.3f B%.3f", redGain, greenGain, blueGain)
        guard let temperature, let tint else { return gains }
        return gains + String(format: " · %.0f K · tint %+.1f", temperature, tint)
    }

    /// Largest relative per-channel difference between two readings.
    func gainVariation(from other: WhiteBalanceReading) -> Double {
        func relative(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(0.0001, max(a, b)) }
        return max(relative(redGain, other.redGain), relative(greenGain, other.greenGain), relative(blueGain, other.blueGain))
    }
}

// MARK: - Lens

/// The physical lens a bracket was photographed with, plus what later geometry correction needs.
struct CaptureLensRecord: Codable, Hashable, Sendable {
    var cameraUniqueID: String
    var deviceType: String
    var lens: PreferredLens?
    var focalLengthMM: Double?
    var focalLengthEquivalentMM: Double?
    var fieldOfViewDegrees: Double?
    var zoomFactor: Double
    var lensAperture: Double?
    var lensModel: String?
    /// Whether the output could deliver intrinsic calibration data. Not requested for brackets:
    /// recorded so the geometry phase knows what this device can offer.
    var calibrationDataSupported: Bool
}

// MARK: - Quality

/// Internal verdict on how HDR-ready a bracket is. Not a rejection: HDR decides the final result.
enum CaptureQualityClass: String, Codable, Hashable, Sendable {
    case good = "CAPTURE_GOOD"
    case warning = "CAPTURE_WARNING"
    case poor = "CAPTURE_POOR"

    var devLabel: String { rawValue }
}

/// Everything Phase D3 measures about one shutter action, stored in its manifest.
struct CaptureQualityReport: Codable, Hashable, Sendable {
    var motion: CaptureMotionSnapshot

    var focusStatus: FocusStatus
    var focusLockSucceeded: Bool
    var focusTimeout: Bool
    /// Lens position moved between frames: the bracket did not hold focus.
    var focusShiftDetected: Bool

    var whiteBalanceLockSucceeded: Bool
    var whiteBalanceVariation: Bool
    var whiteBalanceReference: WhiteBalanceReading?

    var exposureReferenceEstablished: Bool
    var meteringStrategy: MeteringStrategy

    /// Shutter tap → first native capture request.
    var tapToCaptureStartMs: Double?
    /// Focus / white balance / exposure settling before the first request.
    var preparationMs: Double?
    /// First capture request → last frame delivered.
    var bracketDurationMs: Double?
    /// First → last sensor timestamp.
    var exposureSpanMs: Double?
    /// Time between consecutive frames (0→1, 1→2, …).
    var frameIntervalsMs: [Double]

    var lens: CaptureLensRecord?
    var requestedExposureValues: [Double]
    var ladderSource: LadderSource

    var deviceCaptureProfileVersion: String
    var calibrationStatus: CalibrationStatus

    var capturedOffline: Bool
    var thermalState: String?
    var memoryFootprintMB: Double?

    var qualityClass: CaptureQualityClass
    var qualityReasons: [String]

    var stabilityScore: Double? { motion.stabilityScore }
    var motionWarning: MotionAssessment { motion.assessment }
    var rollAngle: Double? { motion.rollAngleAtCapture }
    var pitchAngle: Double? { motion.pitchAngleAtCapture }
}

/// Where a bracket's exposure values came from.
enum LadderSource: String, Codable, Hashable, Sendable {
    case standardProfile = "STANDARD_PROFILE"
    case deviceCalibration = "DEVICE_CALIBRATION"

    var devLabel: String { rawValue }
}

// MARK: - Physical QA protocol

/// The standard physical test scenes. Used only to tag development captures.
enum QAScene: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case livingRoomWindow = "A"
    case darkBedroom = "B"
    case whiteKitchen = "C"
    case mixedLighting = "D"
    case smallBathroom = "E"
    case longCorridor = "F"
    case exteriorDaylight = "G"
    case exteriorSunset = "H"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .livingRoomWindow: "Living room + bright window"
        case .darkBedroom: "Dark bedroom"
        case .whiteKitchen: "White kitchen"
        case .mixedLighting: "Mixed daylight + warm lamps"
        case .smallBathroom: "Small bathroom"
        case .longCorridor: "Long corridor"
        case .exteriorDaylight: "Exterior daylight"
        case .exteriorSunset: "Exterior sunset / high contrast"
        }
    }

    /// Dataset folder name.
    var folder: String {
        switch self {
        case .livingRoomWindow: "living_room_window"
        case .darkBedroom: "dark_bedroom"
        case .whiteKitchen: "white_kitchen"
        case .mixedLighting: "mixed_lighting"
        case .smallBathroom: "bathroom"
        case .longCorridor: "corridor"
        case .exteriorDaylight: "exterior_daylight"
        case .exteriorSunset: "exterior_sunset"
        }
    }
}

/// How the phone was held for a QA capture.
enum QAHoldCondition: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case tripod = "TRIPOD"
    case handheld = "HANDHELD"
    case intentionalMotion = "INTENTIONAL_MOTION"

    var id: String { rawValue }
}

/// Marks a capture as part of the development QA dataset. Untagged captures are never exported.
struct CameraQATag: Codable, Hashable, Sendable {
    var scene: QAScene
    var condition: QAHoldCondition
    var note: String?
}
