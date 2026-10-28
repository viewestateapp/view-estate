import Foundation

/// Proof of what ONE shutter action physically produced, built from real callbacks and real
/// files on disk — never from what was requested.
///
/// A frame only counts as real once AVFoundation called back with image data, the bytes were
/// persisted, the checksum read back from disk matches, and no other frame of the attempt has
/// the same checksum. `validatedProfile` names the ladder the device truly delivered: a FULL_9
/// request that produced seven distinct exposures is reported as such.
nonisolated struct BracketAudit: Codable, Hashable, Sendable {
    var requestedProfile: CaptureProfile
    var requestedExposures: Int
    /// Native `capturePhoto` requests issued (a 9-frame ladder on an 8-frame camera needs two).
    var nativeRequests: Int
    /// Frames per native request, in order.
    var framesPerRequest: [Int]
    /// Every `didFinishProcessingPhoto` callback received, successful or not.
    var callbacks: Int
    /// Callbacks that carried an error or no image data.
    var callbackErrors: Int
    /// Callbacks whose ladder position was already taken — a second write would have overwritten.
    var indexCollisions: Int
    /// Frames whose file exists on disk with the recorded size.
    var persistedFiles: Int
    /// Frames whose SHA-256, recomputed from disk, matches the manifest.
    var verifiedChecksums: Int
    var uniqueHashes: Int
    /// Persisted ∧ checksum-verified ∧ unique.
    var realFrames: Int
    var ev0Frames: Int
    /// Exposure levels that genuinely differ (≥ 1/3 EV apart, from shutter × ISO when reported).
    var distinctExposureLevels: Int
    /// Adjacent requested EVs the camera actually photographed at the same exposure.
    var duplicateExposurePairs: [String]
    /// Measured exposure of each frame relative to EV 0, in EV, ladder order.
    var measuredRelativeEV: [Double]
    var singleCamera: Bool
    var lensPositionSpread: Double?
    var whiteBalanceGainSpread: Double?
    var validatedProfile: CaptureProfile
    /// `didFinishProcessingPhoto` callbacks per native request, in order. `nil` on earlier manifests.
    var callbacksPerRequest: [Int]? = nil
    /// `expectedPhotoCount` AVFoundation resolved for each native request. `nil` on earlier manifests.
    var expectedPhotoCountPerRequest: [Int]? = nil
    /// NATIVE when read from `AVCaptureResolvedPhotoSettings`, REQUESTED when only the request size is known.
    var expectedPhotoCountSource: String? = nil

    /// Every requested exposure exists as a real, unique, materially different file.
    var isTruthful: Bool {
        callbacks == requestedExposures
            && callbackErrors == 0
            && indexCollisions == 0
            && realFrames == requestedExposures
            && distinctExposureLevels == requestedExposures
            && ev0Frames == 1
    }

    /// Enough real, distinct material for an HDR merge: EV 0 plus darker and brighter evidence.
    var supportsHDR: Bool {
        ev0Frames == 1 && realFrames >= 3 && distinctExposureLevels >= 3
            && measuredRelativeEV.contains { $0 < -0.3 } && measuredRelativeEV.contains { $0 > 0.3 }
    }

    var verdictLabel: String {
        if isTruthful { return "TRUTHFUL \(requestedProfile.devLabel)" }
        return "\(requestedProfile.devLabel) requested · real \(validatedProfile.devLabel)"
    }
}

/// Builds a `BracketAudit` from the frames of an attempt and the files actually on disk.
nonisolated enum BracketAuditor {
    /// Minimum separation for two exposures to count as different.
    static let distinctGapEV = 1.0 / 3.0

    struct CallbackEvidence: Sendable, Hashable {
        var nativeRequests: Int
        var framesPerRequest: [Int]
        var callbacks: Int
        var callbackErrors: Int
        var indexCollisions: Int
        var callbacksPerRequest: [Int] = []
        var expectedPhotoCountPerRequest: [Int] = []
        var expectedPhotoCountSource: String? = nil

        static let unknown = CallbackEvidence(
            nativeRequests: 0, framesPerRequest: [], callbacks: 0, callbackErrors: 0, indexCollisions: 0
        )
    }

    static func audit(
        frames: [CaptureFrame],
        plan: BracketPlan,
        evidence: CallbackEvidence,
        verifyFromDisk: Bool = true
    ) -> BracketAudit {
        let ordered = frames.sorted { $0.sequenceIndex < $1.sequenceIndex }

        var persisted: Set<UUID> = []
        var verified: Set<UUID> = []
        for frame in ordered {
            guard frame.byteCount > 0, CaptureBundleStore.fileSize(frame) == frame.byteCount else { continue }
            persisted.insert(frame.id)
            if !verifyFromDisk {
                verified.insert(frame.id)
                continue
            }
            if let data = CaptureBundleStore.loadData(frame), CaptureBundleStore.checksum(data) == frame.checksum {
                verified.insert(frame.id)
            }
        }

        var checksumCounts: [String: Int] = [:]
        for frame in ordered where !frame.checksum.isEmpty {
            checksumCounts[frame.checksum, default: 0] += 1
        }
        let real = ordered.filter {
            persisted.contains($0.id) && verified.contains($0.id) && checksumCounts[$0.checksum] == 1
        }

        let relative = relativeExposures(ordered)
        let measured = ordered.map { relative[$0.id] ?? $0.requestedEV }
        let realMeasured = real.map { relative[$0.id] ?? $0.requestedEV }
        let distinct = distinctLevels(realMeasured)

        var duplicatePairs: [String] = []
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let a = relative[previous.id] ?? previous.requestedEV
            let b = relative[next.id] ?? next.requestedEV
            if abs(b - a) < distinctGapEV {
                duplicatePairs.append("\(previous.evLabel)/\(next.evLabel)")
            }
        }

        let lensPositions = ordered.compactMap(\.lensPosition)
        let lensSpread = lensPositions.isEmpty ? nil : (lensPositions.max() ?? 0) - (lensPositions.min() ?? 0)

        var gainSpread: Double?
        let readings = ordered.compactMap(\.whiteBalance)
        if let first = readings.first {
            gainSpread = readings.map { $0.gainVariation(from: first) }.max()
        }

        let requested = plan.expectedFrameCount
        let usable = min(real.count, distinct)
        let validated: CaptureProfile
        if real.count == requested, distinct == requested, evidence.callbacks == requested || evidence.callbacks == 0 {
            validated = plan.profile
        } else {
            validated = CaptureProfile.family(frameCount: usable)
        }

        return BracketAudit(
            requestedProfile: plan.profile,
            requestedExposures: requested,
            nativeRequests: evidence.nativeRequests,
            framesPerRequest: evidence.framesPerRequest,
            callbacks: evidence.callbacks,
            callbackErrors: evidence.callbackErrors,
            indexCollisions: evidence.indexCollisions,
            persistedFiles: persisted.count,
            verifiedChecksums: verified.count,
            uniqueHashes: checksumCounts.count,
            realFrames: real.count,
            ev0Frames: real.filter(\.isReferenceExposure).count,
            distinctExposureLevels: distinct,
            duplicateExposurePairs: duplicatePairs,
            measuredRelativeEV: measured,
            singleCamera: Set(ordered.map(\.cameraID)).count <= 1 && Set(ordered.map(\.lensType)).count <= 1,
            lensPositionSpread: lensSpread,
            whiteBalanceGainSpread: gainSpread,
            validatedProfile: validated,
            callbacksPerRequest: evidence.callbacksPerRequest.isEmpty ? nil : evidence.callbacksPerRequest,
            expectedPhotoCountPerRequest: evidence.expectedPhotoCountPerRequest.isEmpty
                ? nil : evidence.expectedPhotoCountPerRequest,
            expectedPhotoCountSource: evidence.expectedPhotoCountSource
        )
    }

    /// Exposure of every frame relative to EV 0, in EV. Uses what the sensor really did —
    /// shutter time × ISO — when every frame reports it, otherwise the reported bias.
    static func relativeExposures(_ frames: [CaptureFrame]) -> [UUID: Double] {
        guard let reference = frames.first(where: \.isReferenceExposure) else { return [:] }

        let hasPhysical = frames.allSatisfy {
            ($0.exposureDurationSeconds ?? 0) > 0 && ($0.iso ?? 0) > 0
        }
        var output: [UUID: Double] = [:]
        if hasPhysical,
           let t0 = reference.exposureDurationSeconds, let iso0 = reference.iso {
            let base = t0 * iso0
            for frame in frames {
                let value = (frame.exposureDurationSeconds ?? t0) * (frame.iso ?? iso0)
                output[frame.id] = log2(value / base)
            }
            return output
        }
        let referenceBias = reference.actualExposureBias ?? reference.requestedEV
        for frame in frames {
            output[frame.id] = (frame.actualExposureBias ?? frame.requestedEV) - referenceBias
        }
        return output
    }

    /// Number of exposure levels separated by at least `distinctGapEV`.
    static func distinctLevels(_ values: [Double]) -> Int {
        let sorted = values.sorted()
        guard var last = sorted.first else { return 0 }
        var count = 1
        for value in sorted.dropFirst() where value - last >= distinctGapEV {
            count += 1
            last = value
        }
        return count
    }
}
