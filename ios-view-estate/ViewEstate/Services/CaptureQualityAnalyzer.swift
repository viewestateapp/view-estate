import Foundation

/// What the camera did while preparing one bracket, before any frame was taken.
struct SequencePreparation: Sendable, Hashable {
    var focusStatus: FocusStatus
    var focusLock: LockOutcome
    var focusTimeout: Bool
    var whiteBalanceLock: LockOutcome
    var whiteBalanceReference: WhiteBalanceReading?
    var exposureReferenceEstablished: Bool
    var meteringStrategy: MeteringStrategy
    var preparationMs: Double

    static let unavailable = SequencePreparation(
        focusStatus: .unavailable,
        focusLock: .unsupported,
        focusTimeout: false,
        whiteBalanceLock: .unsupported,
        whiteBalanceReference: nil,
        exposureReferenceEstablished: false,
        meteringStrategy: .centerWeighted,
        preparationMs: 0
    )
}

/// Inputs for grading one bracket. Plain values only, so the grading is fully testable.
struct CaptureQualityInput: Sendable {
    var frames: [CaptureFrame]
    var motion: CaptureMotionSnapshot
    var preparation: SequencePreparation
    var calibration: CameraCalibrationProfile
    var requestedExposureValues: [Double]
    var ladderSource: LadderSource
    var lens: CaptureLensRecord?
    var tapToCaptureStartMs: Double?
    var bracketDurationMs: Double?
    var capturedOffline: Bool
    var thermalState: String?
    var memoryFootprintMB: Double?
}

/// Grades a bracket for HDR-readiness. Never alters a frame, never rejects a capture.
///
/// GOOD    — stable, focus and white balance held, EV 0 reference settled.
/// WARNING — usable, but something was not ideal (minor motion, a lock unavailable, a timeout).
/// POOR    — the frames are inconsistent with each other (severe motion, focus or colour drift).
enum CaptureQualityAnalyzer {
    /// Lens-position travel between frames that counts as a focus change (0…1 scale).
    static let focusShiftTolerance = 0.02

    nonisolated static func report(_ input: CaptureQualityInput) -> CaptureQualityReport {
        let ordered = input.frames.sorted { $0.sequenceIndex < $1.sequenceIndex }
        let focusShift = focusShiftDetected(ordered)
        let whiteBalanceVariation = whiteBalanceVariation(ordered, strategy: input.calibration.whiteBalanceStrategy)
        let mixedCamera = Set(ordered.map(\.cameraID)).count > 1

        var poor: [String] = []
        var warnings: [String] = []

        switch input.motion.assessment {
        case .severe: poor.append(MotionAssessment.severe.rawValue)
        case .warning: warnings.append(MotionAssessment.warning.rawValue)
        case .unavailable: warnings.append("MOTION_SENSOR_UNAVAILABLE")
        case .none: break
        }
        if focusShift { poor.append("FOCUS_SHIFT") }
        if whiteBalanceVariation { poor.append("WHITE_BALANCE_VARIATION") }
        if mixedCamera { poor.append(CameraError.cameraChanged.rawValue) }

        if input.preparation.focusTimeout { warnings.append(CameraError.focusTimeout.rawValue) }
        if input.preparation.focusLock != .succeeded { warnings.append("FOCUS_LOCK_\(input.preparation.focusLock.rawValue)") }
        if input.preparation.whiteBalanceLock != .succeeded {
            warnings.append("WHITE_BALANCE_LOCK_\(input.preparation.whiteBalanceLock.rawValue)")
        }
        if !input.preparation.exposureReferenceEstablished { warnings.append("EXPOSURE_REFERENCE_UNSETTLED") }

        let qualityClass: CaptureQualityClass = !poor.isEmpty ? .poor : (!warnings.isEmpty ? .warning : .good)

        let stamps = timestamps(ordered)
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let span = stamps.count > 1 ? ((stamps.last ?? 0) - (stamps.first ?? 0)) * 1000 : nil

        return CaptureQualityReport(
            motion: input.motion,
            focusStatus: input.preparation.focusStatus,
            focusLockSucceeded: input.preparation.focusLock == .succeeded,
            focusTimeout: input.preparation.focusTimeout,
            focusShiftDetected: focusShift,
            whiteBalanceLockSucceeded: input.preparation.whiteBalanceLock == .succeeded,
            whiteBalanceVariation: whiteBalanceVariation,
            whiteBalanceReference: input.preparation.whiteBalanceReference,
            exposureReferenceEstablished: input.preparation.exposureReferenceEstablished,
            meteringStrategy: input.preparation.meteringStrategy,
            tapToCaptureStartMs: input.tapToCaptureStartMs,
            preparationMs: input.preparation.preparationMs,
            bracketDurationMs: input.bracketDurationMs,
            exposureSpanMs: span,
            frameIntervalsMs: intervals,
            lens: input.lens,
            requestedExposureValues: input.requestedExposureValues,
            ladderSource: input.ladderSource,
            deviceCaptureProfileVersion: input.calibration.versionLabel,
            calibrationStatus: input.calibration.status,
            capturedOffline: input.capturedOffline,
            thermalState: input.thermalState,
            memoryFootprintMB: input.memoryFootprintMB,
            qualityClass: qualityClass,
            qualityReasons: poor + warnings
        )
    }

    /// The lens moved between exposures — focus was not held across the bracket.
    nonisolated static func focusShiftDetected(_ frames: [CaptureFrame]) -> Bool {
        let positions = frames.compactMap(\.lensPosition)
        guard positions.count > 1, let low = positions.min(), let high = positions.max() else { return false }
        return high - low > focusShiftTolerance
    }

    /// Colour drifted between exposures more than the strategy tolerates.
    nonisolated static func whiteBalanceVariation(_ frames: [CaptureFrame], strategy: WhiteBalanceStrategy) -> Bool {
        let readings = frames.compactMap(\.whiteBalance)
        guard readings.count > 1, let reference = readings.first else { return false }
        if readings.contains(where: { $0.gainVariation(from: reference) > strategy.maxGainVariation }) { return true }
        let temperatures = readings.compactMap(\.temperature)
        if let low = temperatures.min(), let high = temperatures.max(), high - low > strategy.maxTemperatureVariationK {
            return true
        }
        return false
    }

    private nonisolated static func timestamps(_ ordered: [CaptureFrame]) -> [Double] {
        if ordered.allSatisfy({ $0.sensorTimestampSeconds != nil }) {
            return ordered.compactMap(\.sensorTimestampSeconds)
        }
        return ordered.map { $0.capturedAt.timeIntervalSinceReferenceDate }
    }
}

// MARK: - Storage

/// Decides whether a bracket can be started without running out of space halfway through.
enum CaptureStoragePolicy {
    /// Conservative size of one full-quality JPEG exposure when nothing has been measured yet.
    static let fallbackFrameBytes: Int64 = 6_000_000
    static let safetyMultiplier = 1.5
    /// Space always left free for the system and the manifest.
    static let reserveBytes: Int64 = 150_000_000

    static func requiredBytes(frameCount: Int, averageFrameBytes: Int64?) -> Int64 {
        let perFrame = max(averageFrameBytes ?? fallbackFrameBytes, 500_000)
        return Int64(Double(perFrame) * Double(max(1, frameCount)) * safetyMultiplier) + reserveBytes
    }

    static func hasRoom(frameCount: Int, averageFrameBytes: Int64?, availableBytes: Int64?) -> Bool {
        // When the system cannot answer, photography is not blocked on a guess.
        guard let availableBytes else { return true }
        return availableBytes >= requiredBytes(frameCount: frameCount, averageFrameBytes: averageFrameBytes)
    }

    /// Space iOS reports as available for important, user-initiated data.
    nonisolated static func availableBytes() -> Int64? {
        guard let root = try? CaptureBundleStore.root(),
              let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Device health

/// Memory and thermal readings for repeated-capture and stress tests. Technical metadata only.
enum DeviceHealthProbe {
    /// Physical memory footprint of the app, in MB — the figure iOS uses for memory pressure.
    nonisolated static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    nonisolated static func thermalStateLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "NOMINAL"
        case .fair: "FAIR"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "UNKNOWN"
        }
    }
}

/// One shutter action as seen by the repeated-capture / stress diagnostics.
struct CaptureRunMetric: Sendable, Hashable, Identifiable {
    var id: UUID { clientCaptureID }
    var clientCaptureID: UUID
    var at: Date
    var succeeded: Bool
    var frameCount: Int
    var bracketDurationMs: Double?
    var tapToCaptureStartMs: Double?
    var memoryFootprintMB: Double?
    var thermalState: String
    var qualityClass: CaptureQualityClass?
    var failureCode: String?
}
