import Foundation

/// Chooses the best exposure ladder the real camera can deliver safely.
///
/// Preference is FULL_9 → STANDARD_7 → COMPACT_5 → BASIC_3 → SINGLE. A camera that cannot reach
/// ±4 EV never fails the whole capture: it simply photographs the widest ladder it does support.
/// A device calibration profile may narrow that ceiling or replace the ladder with its own
/// recommended (possibly fractional) exposure set — but only when the hardware supports every value.
enum CaptureProfileService {
    /// Small slack so a device reporting, say, 2.9999 EV still qualifies for a ±3 ladder.
    static let biasTolerance = 0.05

    /// The complete plan — profile plus the native bracket requests it will be captured in.
    static func plan(
        for capabilities: CameraExposureCapabilities,
        calibration: CameraCalibrationProfile = .generic
    ) -> BracketPlan {
        var plan = basePlan(for: capabilities, calibration: calibration)
        plan.calibrationVersion = calibration.versionLabel
        return plan
    }

    private static func basePlan(
        for capabilities: CameraExposureCapabilities,
        calibration: CameraCalibrationProfile
    ) -> BracketPlan {
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else {
            return BracketPlan.single
        }
        guard calibration.status.allowsBracketing else {
            return BracketPlan(profile: .single, segments: [[0]], reason: "Bracketing disabled by device calibration.")
        }

        // A device-specific ladder wins when every one of its values is physically reachable.
        if let ladder = CameraCalibrationCatalog.sanitizeLadder(calibration.exposureValues),
           ladder.count >= 2,
           fits(ladder, capabilities: capabilities) {
            return BracketPlan(
                profile: CaptureProfile.family(frameCount: ladder.count),
                segments: segments(ladder, limit: capabilities.maxBracketCount),
                reason: "Device calibration \(calibration.versionLabel) ladder.",
                ladderSource: .deviceCalibration
            )
        }

        let profile = self.profile(for: capabilities, ceiling: calibration.captureProfile)
        guard profile.isBracket else { return BracketPlan.single }

        let reason: String
        if profile == .full9 {
            reason = "Full ±4 EV range supported."
        } else if let ceiling = calibration.captureProfile, ceiling == profile {
            reason = "Device calibration caps the ladder at \(ceiling.devLabel)."
        } else {
            reason = String(
                format: "Device exposure range %.1f…%+.1f EV — widest supported ladder.",
                capabilities.minExposureBias,
                capabilities.maxExposureBias
            )
        }
        return BracketPlan(
            profile: profile,
            segments: segments(profile.exposureValues, limit: capabilities.maxBracketCount),
            reason: reason
        )
    }

    /// The widest ladder whose exposure values all fall inside the device's real bias range,
    /// never wider than an optional calibration ceiling.
    static func profile(
        for capabilities: CameraExposureCapabilities,
        ceiling: CaptureProfile? = nil
    ) -> CaptureProfile {
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else {
            return .single
        }
        let order = CaptureProfile.preferenceOrder
        let start = ceiling.flatMap { order.firstIndex(of: $0) } ?? 0
        for candidate in order[start...] where candidate.isBracket {
            if supports(candidate, capabilities: capabilities) { return candidate }
        }
        return .single
    }

    /// A ladder is supported when every exposure value it needs is inside the reported range.
    static func supports(_ profile: CaptureProfile, capabilities: CameraExposureCapabilities) -> Bool {
        guard profile.includesReferenceExposure else { return false }
        guard profile.isBracket else { return true }
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else { return false }
        return fits(profile.exposureValues, capabilities: capabilities)
    }

    static func fits(_ values: [Double], capabilities: CameraExposureCapabilities) -> Bool {
        guard let lowest = values.min(), let highest = values.max() else { return false }
        return lowest >= capabilities.minExposureBias - biasTolerance
            && highest <= capabilities.maxExposureBias + biasTolerance
    }

    /// Splits a ladder into consecutive native bracket requests of at most `limit` frames.
    /// Order is preserved, so the sequence index of every frame stays deterministic.
    static func segments(_ values: [Double], limit: Int) -> [[Double]] {
        guard limit >= 1, values.count > limit else { return values.isEmpty ? [] : [values] }

        // Balance the segments so the bracket is not one long request plus a single stray frame.
        let count = Int(ceil(Double(values.count) / Double(limit)))
        let size = Int(ceil(Double(values.count) / Double(count)))

        var segments: [[Double]] = []
        var index = 0
        while index < values.count {
            let end = min(index + size, values.count)
            segments.append(Array(values[index..<end]))
            index = end
        }
        return segments
    }
}

// MARK: - Adaptive profile foundation

/// What a future scene analysis could report before the shutter fires.
/// Nothing produces it yet: device calibration stays the primary source of the ladder.
struct SceneAnalysis: Sendable, Hashable {
    var estimatedDynamicRangeEV: Double?
    var highlightClippingPercent: Double?
    var shadowClippingPercent: Double?
}

/// SceneAnalysis → RecommendedBracketProfile. The seam a future adaptive HDR policy plugs into.
protocol BracketProfileRecommending {
    func recommend(
        capabilities: CameraExposureCapabilities,
        calibration: CameraCalibrationProfile,
        scene: SceneAnalysis?
    ) -> BracketPlan
}

/// Current production policy: the device profile decides; scene analysis is ignored.
struct DeviceProfileRecommender: BracketProfileRecommending {
    func recommend(
        capabilities: CameraExposureCapabilities,
        calibration: CameraCalibrationProfile,
        scene: SceneAnalysis?
    ) -> BracketPlan {
        CaptureProfileService.plan(for: capabilities, calibration: calibration)
    }
}
