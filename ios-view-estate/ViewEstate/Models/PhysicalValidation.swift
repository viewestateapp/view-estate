import Foundation

// Phase D3-V — physical iPhone validation. Development only: nothing here is ever shown to a
// normal user, and nothing here can mark a device CALIBRATED without a person signing it off.

/// Result of one validation item. Absence of evidence is always PENDING — never PASS.
enum ValidationVerdict: String, Codable, Hashable, Sendable, CaseIterable {
    case pending = "PENDING"
    case pass = "PASS"
    case fail = "FAIL"

    /// Any FAIL fails; otherwise any PENDING keeps the item pending; only all-PASS passes.
    nonisolated static func all(_ verdicts: [ValidationVerdict]) -> ValidationVerdict {
        if verdicts.contains(.fail) { return .fail }
        if verdicts.isEmpty || verdicts.contains(.pending) { return .pending }
        return .pass
    }
}

/// Observations only a person looking at the iPhone (or the frames) can make.
enum ManualValidationCheck: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    // Scene A — the most important evidence for future HDR.
    case windowDetailInDarkestFrame = "A_WINDOW_DETAIL_DARKEST"
    case referenceExposureValid = "A_EV0_VALID"
    case interiorShadowsInBrightestFrame = "A_SHADOWS_BRIGHTEST"
    // Frame consistency, inspected side by side.
    case noVisibleRefocus = "FOCUS_NO_VISIBLE_REFOCUS"
    case noWhiteBalanceJump = "WB_NO_VISIBLE_JUMP"
    case sameLensAllFrames = "LENS_SAME_ALL_FRAMES"
    case orientationConsistent = "ORIENTATION_CONSISTENT"
    // Level.
    case levelFollowsTilt = "LEVEL_FOLLOWS_TILT"
    case levelWarnsOutsideTolerance = "LEVEL_WARNS_OUTSIDE_TOLERANCE"
    case sourceNotRotated = "LEVEL_SOURCE_NOT_ROTATED"
    // Offline & restart.
    case offlineCapturesVisibleAfterRestart = "OFFLINE_VISIBLE_AFTER_RESTART"
    case syncResumesSafely = "OFFLINE_SYNC_RESUMES"
    // Interruptions.
    case backgroundForegroundRecovers = "INTERRUPT_BACKGROUND"
    case lockUnlockRecovers = "INTERRUPT_LOCK_UNLOCK"
    case callInterruptionRecovers = "INTERRUPT_CALL"
    // Low storage.
    case lowStorageShowsFriendlyMessage = "LOW_STORAGE_MESSAGE"
    // Whole session.
    case noCameraCrash = "NO_CAMERA_CRASH"

    var id: String { rawValue }

    var group: String {
        switch self {
        case .windowDetailInDarkestFrame, .referenceExposureValid, .interiorShadowsInBrightestFrame:
            "Scene A · window"
        case .noVisibleRefocus, .noWhiteBalanceJump, .sameLensAllFrames, .orientationConsistent:
            "Frames side by side"
        case .levelFollowsTilt, .levelWarnsOutsideTolerance, .sourceNotRotated:
            "Level"
        case .offlineCapturesVisibleAfterRestart, .syncResumesSafely:
            "Offline & restart"
        case .backgroundForegroundRecovers, .lockUnlockRecovers, .callInterruptionRecovers:
            "Interruptions"
        case .lowStorageShowsFriendlyMessage:
            "Low storage"
        case .noCameraCrash:
            "Whole session"
        }
    }

    var title: String {
        switch self {
        case .windowDetailInDarkestFrame: "Darkest useful frame shows window / exterior detail"
        case .referenceExposureValid: "EV 0 is a valid reference exposure"
        case .interiorShadowsInBrightestFrame: "Brightest useful frame improves interior shadows"
        case .noVisibleRefocus: "No visible refocus between exposures"
        case .noWhiteBalanceJump: "No strong temperature / tint / colour jump between exposures"
        case .sameLensAllFrames: "Same lens and framing in every frame"
        case .orientationConsistent: "Every frame has the same, correct orientation"
        case .levelFollowsTilt: "Level line follows real tilt"
        case .levelWarnsOutsideTolerance: "Level warns outside the tolerance"
        case .sourceNotRotated: "Stored photographs are not rotated by the level"
        case .offlineCapturesVisibleAfterRestart: "Offline captures still listed after relaunch"
        case .syncResumesSafely: "Sync resumes after reconnecting, no duplicates"
        case .backgroundForegroundRecovers: "Background → foreground: camera recovers"
        case .lockUnlockRecovers: "Lock → unlock: camera recovers"
        case .callInterruptionRecovers: "Call / camera interruption: camera recovers (optional)"
        case .lowStorageShowsFriendlyMessage: "Low storage: bracket refused with friendly message"
        case .noCameraCrash: "No camera crash or frozen session during the whole validation"
        }
    }

    /// The call interruption is "if practical": it never blocks a verdict when untested.
    var isOptional: Bool { self == .callInterruptionRecovers }
}

/// Independent verdict on the ultra-wide lens. Never makes it the default.
enum LensClassification: String, Codable, Hashable, Sendable, CaseIterable {
    case pending = "PENDING"
    case supported = "SUPPORTED"
    case limited = "LIMITED"
    case disabled = "DISABLED"
}

/// The human calibration decision for this device. Starts PENDING.
enum CalibrationDecision: String, Codable, Hashable, Sendable, CaseIterable {
    case pending = "PENDING"
    case calibrated = "CALIBRATED"
    case limited = "LIMITED"
    case unsupported = "UNSUPPORTED"
}

/// Camera session lifecycle events, counted as interruption-recovery evidence.
enum CameraSessionEventKind: String, Codable, Hashable, Sendable {
    case appLaunched = "APP_LAUNCHED"
    case interrupted = "SESSION_INTERRUPTED"
    case interruptionEnded = "INTERRUPTION_ENDED"
    case runtimeError = "RUNTIME_ERROR"
    case recovered = "SESSION_RECOVERED"
    case recoveryFailed = "RECOVERY_FAILED"
}

struct CameraSessionEvent: Codable, Hashable, Sendable {
    var kind: CameraSessionEventKind
    var at: Date
    var launchID: UUID
}

/// One shutter action, persisted so the stress, offline and restart evidence survives relaunches.
struct ValidationRun: Codable, Hashable, Sendable, Identifiable {
    var id: UUID { clientCaptureID }
    var clientCaptureID: UUID
    var at: Date
    var launchID: UUID
    var succeeded: Bool
    var failureCode: String?
    var profile: String?
    var lens: String?
    var frameCount: Int
    var totalBytes: Int
    var capturedOffline: Bool
    var tapToCaptureStartMs: Double?
    var tapToFirstFrameMs: Double?
    var bracketDurationMs: Double?
    /// Frame files written during the bracket.
    var framePersistMs: Double?
    /// Bundle validation + manifest commit after the last frame.
    var finalizeMs: Double?
    var memoryFootprintMB: Double?
    var thermalState: String
    var qualityClass: CaptureQualityClass?
}

/// Everything collected during one physical validation of one device.
struct PhysicalValidationSession: Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var startedAt: Date
    var deviceModel: String
    var systemVersion: String
    var appVersion: String
    /// A simulator session is recorded but can never produce evidence.
    var isSimulator: Bool
    var creditsBefore: Int
    var creditTransactionsBefore: Int
    var runs: [ValidationRun] = []
    var events: [CameraSessionEvent] = []
    var manualChecks: [String: ValidationVerdict] = [:]
    var ultraWide: LensClassification = .pending
    var ultraWideNotes: String = ""
    /// Profile a person chose after reviewing the evidence (FULL_9…BASIC_3 or CUSTOM).
    var recommendedProfile: String?
    var customLadder: String = ""
    var decision: CalibrationDecision = .pending
    var signedOffBy: String = ""
    var signedOffAt: Date?
    var notes: String = ""

    static let maxRuns = 500
    static let maxEvents = 500

    func verdict(_ check: ManualValidationCheck) -> ValidationVerdict {
        manualChecks[check.rawValue] ?? .pending
    }

    var launchCount: Int {
        Set(events.filter { $0.kind == .appLaunched }.map(\.launchID)).count
    }

    /// Shutter actions that reused a client capture id. Must always be zero.
    var duplicateClientCaptureIDs: Int {
        runs.count - Set(runs.map(\.clientCaptureID)).count
    }
}
