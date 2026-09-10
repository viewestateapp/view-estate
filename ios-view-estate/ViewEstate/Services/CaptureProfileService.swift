import Foundation

/// Chooses the best exposure ladder the real camera can deliver safely.
///
/// Preference is FULL_9 → STANDARD_7 → COMPACT_5 → BASIC_3 → SINGLE. A camera that cannot reach
/// ±4 EV never fails the whole capture: it simply photographs the widest ladder it does support.
enum CaptureProfileService {
    /// Small slack so a device reporting, say, 2.9999 EV still qualifies for a ±3 ladder.
    private static let biasTolerance = 0.05

    /// The complete plan — profile plus the native bracket requests it will be captured in.
    static func plan(for capabilities: CameraExposureCapabilities) -> BracketPlan {
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else {
            return BracketPlan.single
        }

        let profile = self.profile(for: capabilities)
        guard profile.isBracket else { return BracketPlan.single }

        let segments = segments(profile.exposureValues, limit: capabilities.maxBracketCount)
        let reason: String
        if profile == .full9 {
            reason = "Full ±4 EV range supported."
        } else {
            reason = String(
                format: "Device exposure range %.1f…%+.1f EV — widest supported ladder.",
                capabilities.minExposureBias,
                capabilities.maxExposureBias
            )
        }
        return BracketPlan(profile: profile, segments: segments, reason: reason)
    }

    /// The widest ladder whose exposure values all fall inside the device's real bias range.
    static func profile(for capabilities: CameraExposureCapabilities) -> CaptureProfile {
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else {
            return .single
        }
        for candidate in CaptureProfile.preferenceOrder where candidate.isBracket {
            if supports(candidate, capabilities: capabilities) { return candidate }
        }
        return .single
    }

    /// A ladder is supported when every exposure value it needs is inside the reported range.
    static func supports(_ profile: CaptureProfile, capabilities: CameraExposureCapabilities) -> Bool {
        guard profile.includesReferenceExposure else { return false }
        guard profile.isBracket else { return true }
        guard capabilities.supportsBracketCapture, capabilities.maxBracketCount >= 2 else { return false }
        return Double(profile.minimumEV) >= capabilities.minExposureBias - biasTolerance
            && Double(profile.maximumEV) <= capabilities.maxExposureBias + biasTolerance
    }

    /// Splits a ladder into consecutive native bracket requests of at most `limit` frames.
    /// Order is preserved, so the sequence index of every frame stays deterministic.
    static func segments(_ values: [Int], limit: Int) -> [[Int]] {
        guard limit >= 1, values.count > limit else { return values.isEmpty ? [] : [values] }

        // Balance the segments so the bracket is not one long request plus a single stray frame.
        let count = Int(ceil(Double(values.count) / Double(limit)))
        let size = Int(ceil(Double(values.count) / Double(count)))

        var segments: [[Int]] = []
        var index = 0
        while index < values.count {
            let end = min(index + size, values.count)
            segments.append(Array(values[index..<end]))
            index = end
        }
        return segments
    }
}
