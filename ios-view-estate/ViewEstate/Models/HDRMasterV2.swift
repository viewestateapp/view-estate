import Foundation

// MARK: - Pipeline selection

/// Which HDR engine prepares new captures. Development-only switch; V1 is always kept.
nonisolated enum HDRPipelineSelection: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case v1 = "V1"
    case v2 = "V2"
    /// Runs V1, then V2, on the same bracket so both masters can be compared. V2 is shown.
    case both = "V1+V2"

    var id: String { rawValue }

    var runsV1: Bool { self != .v2 }
    var runsV2: Bool { self != .v1 }
}

/// Which pipeline produced the master a capture currently shows.
nonisolated enum HDRMasterVersion: String, Codable, Hashable, Sendable {
    case v1 = "V1"
    case v2 = "V2"
}

// MARK: - Processing profile

/// Every tunable of VE-HDR 2.0 lives here — nothing is hard-coded in the stages. A new look is a
/// new profile, never an edit scattered through the pipeline.
nonisolated struct HDRProcessingProfile: Hashable, Sendable {
    var version: String

    // Resolution & memory
    /// Longest edge of the working image. `0` = the full source resolution.
    var preferredMaxPixel: Int
    /// Tried in order when memory is short.
    var fallbackMaxPixels: [Int]
    var alignmentMaxPixel: Int
    var previewMaxPixel: Int
    var thumbnailMaxPixel: Int
    /// Estimated simultaneous bytes per working pixel (buffers alive at the same time).
    var bytesPerWorkingPixel: Double
    /// Free memory must exceed the estimate by this factor.
    var memoryHeadroom: Double
    var masterJPEGQuality: Double
    var previewJPEGQuality: Double

    // Alignment (every frame directly to EV 0)
    var maxTranslationPercent: Double
    var maxRotationDegrees: Double
    var maxScaleDelta: Double
    /// Search reaches past the limits so an unsafe transform is detected, not clamped.
    var rotationSearchDegrees: Double
    var scaleSearchDelta: Double
    var minAlignmentConfidence: Double
    /// Below this share of textured pixels a frame is kept unaligned (nothing to lock onto).
    var minTexturedFraction: Double

    // Crop
    var targetCropPercent: Double
    var maxCropPercent: Double

    // White balance (EV 0 is the reference)
    var whiteBalanceMaxCorrection: Double

    // Motion & deghost
    /// Departure from the exposure-predicted value, as a share of full scale.
    var motionThreshold: Float
    var motionDilation: Int
    var motionDetectedPercent: Double
    var ghostingMediumPercent: Double
    var ghostingHighPercent: Double
    var ghostingExcessivePercent: Double
    var deghostStrength: Float
    var minDeghostConfidence: Double

    // Merge
    var gamma: Float
    var clipLevel: Float
    var clippedWeightFactor: Float
    var noiseFloorLevel: Float
    var weightFloor: Float

    // Tone mapping
    var keyScale: Float
    var whitePercentile: Double
    var blackPercentile: Double
    var blackPointStrength: Float
    var localContrast: Float
    var localContrastLimit: Float
    var localContrastRadiusFraction: Double
    var contrast: Float
    var saturation: Float
    var highlightDesaturation: Float
    /// Soft highlight shoulder (display-linear): values above the knee roll off towards the
    /// ceiling so bright windows keep detail instead of landing on pure white.
    var highlightKnee: Float
    var highlightCeiling: Float
    /// Black point never removes more than this many encoded 8-bit levels (flare/noise only).
    var maxBlackPointLevels: Float
    /// Gentle deep-shadow lift (display-linear): ×(1 + lift) at black, fading to ×1 at the toe.
    var shadowLift: Float
    var shadowToe: Float
    /// The S-curve fades in above this encoded value so it never crushes deep shadows.
    var contrastToe: Float

    // Denoise & sharpen
    var denoiseStrength: Float
    var denoiseEdgeLevels: Float
    var sharpenAmount: Float
    var sharpenThresholdLevels: Float
    var sharpenOvershootLevels: Float

    // Quality check
    var maxHighlightClipPercent: Double
    var maxShadowClipPercent: Double
    var warnAlignmentConfidence: Double
    var maxNoiseEstimate: Double
    var minSharpnessEstimate: Double
    var minMasterLongSide: Int

    var timeoutSeconds: Double
    /// Developer HDR Lab images (aligned exposures, motion mask). Small, low resolution.
    var writesLabArtifacts: Bool

    static let realEstateStandardV2 = HDRProcessingProfile(
        version: "REAL_ESTATE_STANDARD_V2",
        preferredMaxPixel: 0,
        fallbackMaxPixels: [3024, 2048],
        alignmentMaxPixel: 1024,
        previewMaxPixel: 1280,
        thumbnailMaxPixel: 400,
        bytesPerWorkingPixel: 52,
        memoryHeadroom: 1.5,
        masterJPEGQuality: 0.93,
        previewJPEGQuality: 0.85,
        maxTranslationPercent: 3.0,
        maxRotationDegrees: 1.5,
        maxScaleDelta: 0.02,
        rotationSearchDegrees: 2.5,
        scaleSearchDelta: 0.025,
        minAlignmentConfidence: 0.30,
        minTexturedFraction: 0.04,
        targetCropPercent: 5,
        maxCropPercent: 12,
        whiteBalanceMaxCorrection: 0.08,
        motionThreshold: 0.12,
        motionDilation: 2,
        motionDetectedPercent: 0.2,
        ghostingMediumPercent: 1,
        ghostingHighPercent: 8,
        ghostingExcessivePercent: 45,
        deghostStrength: 1,
        minDeghostConfidence: 0.6,
        gamma: 2.2,
        clipLevel: 0.97,
        clippedWeightFactor: 0.02,
        noiseFloorLevel: 0.06,
        weightFloor: 0.0001,
        keyScale: 1.18,
        whitePercentile: 0.997,
        blackPercentile: 0.002,
        blackPointStrength: 0.8,
        localContrast: 0.18,
        localContrastLimit: 0.04,
        localContrastRadiusFraction: 0.012,
        contrast: 0.10,
        saturation: 1.0,
        highlightDesaturation: 0.25,
        highlightKnee: 0.68,
        highlightCeiling: 0.88,
        maxBlackPointLevels: 3,
        shadowLift: 1.0,
        shadowToe: 0.02,
        contrastToe: 0.35,
        denoiseStrength: 0.5,
        denoiseEdgeLevels: 10,
        sharpenAmount: 0.35,
        sharpenThresholdLevels: 2,
        sharpenOvershootLevels: 6,
        maxHighlightClipPercent: 6,
        maxShadowClipPercent: 4,
        warnAlignmentConfidence: 0.55,
        maxNoiseEstimate: 6,
        minSharpnessEstimate: 1.5,
        minMasterLongSide: 1600,
        // A job longer than this fails with V2_TIMEOUT; the queue watchdog enforces the same limit.
        timeoutSeconds: 120,
        writesLabArtifacts: true
    )
}

// MARK: - Per-frame evidence

nonisolated enum HDRAlignmentStatus: String, Codable, Hashable, Sendable {
    case reference = "REFERENCE"
    case aligned = "ALIGNED"
    /// Too little texture to measure: kept with no correction.
    case lowTexture = "LOW_TEXTURE"
    case excluded = "EXCLUDED"
}

/// The rigid transform that maps a pixel of EV 0 to the same scene point in another exposure.
/// Conservative by construction: translation, small rotation about the centre, uniform scale.
nonisolated struct HDRTransformV2: Codable, Hashable, Sendable {
    /// Pixels at processing resolution.
    var translationX: Double
    var translationY: Double
    var rotationDegrees: Double
    var scaleDelta: Double

    static let identity = HDRTransformV2(translationX: 0, translationY: 0, rotationDegrees: 0, scaleDelta: 0)

    func scaled(by factor: Double) -> HDRTransformV2 {
        HDRTransformV2(
            translationX: translationX * factor,
            translationY: translationY * factor,
            rotationDegrees: rotationDegrees,
            scaleDelta: scaleDelta
        )
    }
}

nonisolated struct HDRFrameAlignmentV2: Codable, Hashable, Sendable {
    var frameID: UUID
    var fileName: String
    var evLabel: String
    var relativeEV: Double
    var translationX: Double
    var translationY: Double
    var rotationDegrees: Double
    var scaleDelta: Double
    var alignmentConfidence: Double
    var alignmentStatus: HDRAlignmentStatus
    /// Colour-drift correction towards EV 0 (R, G, B multipliers).
    var whiteBalanceGains: [Double]
    var motionCoveragePercent: Double

    var transform: HDRTransformV2 {
        HDRTransformV2(translationX: translationX, translationY: translationY, rotationDegrees: rotationDegrees, scaleDelta: scaleDelta)
    }
}

nonisolated struct HDRFrameExclusionV2: Codable, Hashable, Sendable {
    var excludedFrameID: UUID
    var fileName: String
    var exclusionReason: String
}

nonisolated struct HDRCropV2: Codable, Hashable, Sendable {
    /// Pixels removed from each side, in the sensor-oriented processing image.
    var cropLeft: Int
    var cropRight: Int
    var cropTop: Int
    var cropBottom: Int
    var sourceWidth: Int
    var sourceHeight: Int

    var cropPercentX: Double { sourceWidth > 0 ? Double(cropLeft + cropRight) / Double(sourceWidth) * 100 : 0 }
    var cropPercentY: Double { sourceHeight > 0 ? Double(cropTop + cropBottom) / Double(sourceHeight) * 100 : 0 }
    var width: Int { sourceWidth - cropLeft - cropRight }
    var height: Int { sourceHeight - cropTop - cropBottom }

    /// Crop fractions as seen on screen, after the EXIF rotation of the photo.
    /// Returns (left, top, right, bottom) shares of the displayed EV 0.
    func displayInsets(exifOrientation: Int) -> (left: Double, top: Double, right: Double, bottom: Double) {
        let l = Double(cropLeft) / Double(max(1, sourceWidth))
        let r = Double(cropRight) / Double(max(1, sourceWidth))
        let t = Double(cropTop) / Double(max(1, sourceHeight))
        let b = Double(cropBottom) / Double(max(1, sourceHeight))
        switch exifOrientation {
        case 3: return (r, b, l, t)
        // 90° clockwise: sensor left → top, top → right, right → bottom, bottom → left.
        case 6: return (b, l, t, r)
        // 90° counter-clockwise: sensor top → left, right → top, bottom → right, left → bottom.
        case 8: return (t, r, b, l)
        default: return (l, t, r, b)
        }
    }
}

nonisolated enum HDRGhostingRisk: String, Codable, Hashable, Sendable {
    case none = "NONE"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
}

nonisolated enum HDRQualityResult: String, Codable, Hashable, Sendable, Comparable {
    case pass = "PASS"
    case warning = "WARNING"
    case fail = "FAIL"

    private var rank: Int {
        switch self {
        case .pass: 0
        case .warning: 1
        case .fail: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

nonisolated struct HDRQualityCheckV2: Codable, Hashable, Sendable {
    var name: String
    var result: HDRQualityResult
    var detail: String
}

// MARK: - Master record

/// The verified VE-HDR 2.0 master of one capture. Lives in `hdr_master_v2.json` next to the
/// exposures and next to — never instead of — a V1 master.
nonisolated struct HDRMasterV2Record: Codable, Hashable, Sendable {
    var assetID: UUID
    var captureID: UUID
    var clientCaptureID: UUID
    var pipelineVersion: String
    var profileVersion: String

    var inputFrameIDs: [UUID]
    var excludedFrameIDs: [UUID]
    var referenceFrameID: UUID
    var referenceFileName: String

    var fileName: String
    var previewFileName: String
    var thumbnailFileName: String
    var width: Int
    var height: Int
    var exifOrientation: Int
    var orientation: CaptureOrientation
    var fileSize: Int
    var previewFileSize: Int
    var checksum: String
    var processingDuration: Double
    var processingWidth: Int
    var processingHeight: Int
    var peakMemoryMB: Double

    var alignments: [HDRFrameAlignmentV2]
    var exclusions: [HDRFrameExclusionV2]
    var alignmentConfidence: Double
    var maxRotationCorrection: Double
    var crop: HDRCropV2
    var cropPercentX: Double
    var cropPercentY: Double

    var motionDetected: Bool
    var motionCoverage: Double
    var ghostingRisk: HDRGhostingRisk
    var deghostApplied: Bool
    var deghostConfidence: Double

    var ev0HighlightClipping: Double
    var ev0ShadowClipping: Double
    var highlightClipping: Double
    var shadowClipping: Double
    var noiseEstimate: Double
    var sharpnessEstimate: Double

    var qualityResult: HDRQualityResult
    var qualityChecks: [HDRQualityCheckV2]
    /// Internal only (GHOSTING_WARNING, CROP_ABOVE_TARGET, …). Never shown to a normal user.
    var warnings: [String]
    var labAlignedFileNames: [String]
    var labMotionMaskFileName: String?
    var createdAt: Date

    var processingResolution: String { "\(processingWidth) × \(processingHeight)" }
    var dimensionDescription: String { "\(width) × \(height)" }
    var sizeDescription: String { String(format: "%.2f MB", Double(fileSize) / 1_048_576) }
    var distinctExposureLevels: Int { inputFrameIDs.count }

    /// The same master in the shape every display surface already understands.
    var displayRecord: HDRMasterRecord {
        HDRMasterRecord(
            assetID: assetID,
            captureID: captureID,
            clientCaptureID: clientCaptureID,
            fileName: fileName,
            previewFileName: previewFileName,
            pixelWidth: width,
            pixelHeight: height,
            exifOrientation: exifOrientation,
            orientation: orientation,
            byteCount: fileSize,
            previewByteCount: previewFileSize,
            checksum: checksum,
            pipelineVersion: pipelineVersion,
            createdAt: createdAt,
            sourceFrameCount: inputFrameIDs.count,
            distinctExposureLevels: inputFrameIDs.count,
            referenceFileName: referenceFileName,
            alignment: alignments.map {
                String(format: "EV %@: %+.1f, %+.1f, %+.2f° %@", $0.evLabel, $0.translationX, $0.translationY, $0.rotationDegrees, $0.alignmentStatus.rawValue)
            },
            processingSeconds: processingDuration,
            ev0HighlightClipPercent: ev0HighlightClipping,
            ev0ShadowClipPercent: ev0ShadowClipping,
            hdrHighlightClipPercent: highlightClipping,
            hdrShadowClipPercent: shadowClipping
        )
    }
}
