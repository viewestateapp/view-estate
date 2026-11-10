import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// VE-HDR 2.0 — a modular, on-device HDR pipeline that runs next to VE-HDR 1.0.
///
/// validate → normalize → align (every frame directly to EV 0) → motion analysis → deghost →
/// exposure-aware merge → tone map → denoise → sharpen → safe 4:3 crop → quality check →
/// write master / preview / thumbnail → verify.
///
/// It never modifies a source exposure, never invents pixels (deghosting only prefers real EV 0
/// content), never warps projectively, and never writes over a V1 master. Costs no AI credits.
nonisolated enum HDRPipelineV2 {
    static let pipelineVersion = "VE-HDR 2.0"
    static let masterFileName = "hdr_master_v2.jpg"
    static let previewFileName = "hdr_preview_v2.jpg"
    static let thumbnailFileName = "hdr_thumb_v2.jpg"
    static let recordFileName = "hdr_master_v2.json"
    static let labMotionMaskFileName = "v2_lab_motion.png"

    static func labAlignedFileName(sequenceIndex: Int) -> String {
        "v2_lab_aligned_\(sequenceIndex).jpg"
    }

    /// Stable error codes. `kind` decides "Erro" (technical) or "Precisa de nova captura".
    enum Code {
        static let inputInvalid = "V2_INPUT_INVALID"
        static let alignmentFailed = "V2_ALIGNMENT_FAILED"
        static let alignmentUnsafe = "V2_ALIGNMENT_UNSAFE"
        static let ghostingExcessive = "V2_GHOSTING_EXCESSIVE"
        static let cropExcessive = "V2_CROP_EXCESSIVE"
        static let mergeFailed = "V2_MERGE_FAILED"
        static let toneMapFailed = "V2_TONEMAP_FAILED"
        static let memoryPressure = "V2_MEMORY_PRESSURE"
        static let outputWriteFailed = "V2_OUTPUT_WRITE_FAILED"
        static let outputVerifyFailed = "V2_OUTPUT_VERIFY_FAILED"
        static let timeout = "V2_TIMEOUT"
    }

    /// Internal warning tags. Recorded, never shown to a normal user.
    enum Warning {
        static let ghosting = "GHOSTING_WARNING"
        static let cropAboveTarget = "CROP_ABOVE_TARGET"
        static let rangeReduced = "RANGE_REDUCED"
        static let full9Incomplete = "FULL_9_INCOMPLETE"
        static let lowAlignmentConfidence = "LOW_ALIGNMENT_CONFIDENCE"
        static let highlightClipping = "HIGHLIGHT_CLIPPING"
        static let shadowClipping = "SHADOW_CLIPPING"
        static let noise = "NOISE_HIGH"
        static let sharpness = "SHARPNESS_LOW"
        static let resolution = "RESOLUTION_REDUCED"
    }

    // MARK: - Entry point

    static func process(
        manifest: CaptureManifest,
        captureID: UUID,
        profile: HDRProcessingProfile = .realEstateStandardV2,
        progress: @Sendable (HDRStage) -> Void
    ) -> Result<HDRMasterV2Record, HDRProcessingFailure> {
        let started = Date()
        let deadline = started.addingTimeInterval(profile.timeoutSeconds)
        var peakMemory = DeviceHealthProbe.memoryFootprintMB() ?? 0
        func sampleMemory() {
            if let value = DeviceHealthProbe.memoryFootprintMB() { peakMemory = max(peakMemory, value) }
        }

        do {
            // 1 · validate
            progress(.validating)
            let inputs = try validate(manifest, profile: profile)
            var warnings = inputs.warnings

            // 2 · low-resolution analysis pass: alignment, colour drift and motion, one frame at a time.
            progress(.decoding)
            guard let referenceURL = CaptureBundleStore.url(for: inputs.reference) else {
                throw failure(Code.alignmentFailed, .technical, "EV 0 path")
            }
            guard let referenceSmall = try? decodeRGBX(url: referenceURL, maxPixel: profile.alignmentMaxPixel) else {
                throw failure(Code.alignmentFailed, .technical, "EV 0 decode")
            }
            let referenceGray = luma(referenceSmall)
            let referenceMTB = MTBReference(referenceGray)
            let smallWidth = referenceSmall.width
            let smallHeight = referenceSmall.height
            sampleMemory()

            var analyses: [FrameAnalysis] = []
            var exclusions: [HDRFrameExclusionV2] = []
            var labAligned: [String] = []
            var unionMotion = [Float](repeating: 0, count: smallWidth * smallHeight)
            var unionBinary = [UInt8](repeating: 0, count: smallWidth * smallHeight)

            for source in inputs.frames {
                try checkDeadline(deadline)
                if source.frame.id == inputs.reference.id {
                    analyses.append(FrameAnalysis(
                        source: source,
                        transform: .identity,
                        confidence: 1,
                        status: .reference,
                        gains: [1, 1, 1],
                        mask: nil,
                        motionPercent: 0
                    ))
                    continue
                }
                guard let url = CaptureBundleStore.url(for: source.frame),
                      let small = try? decodeRGBX(url: url, maxPixel: profile.alignmentMaxPixel)
                else {
                    throw failure(Code.inputInvalid, .technical, "decode \(source.frame.fileName)")
                }
                guard small.width == smallWidth, small.height == smallHeight else {
                    throw failure(Code.inputInvalid, .sourceRejected, "dimensions \(source.frame.fileName)")
                }

                progress(.aligning)
                let gray = luma(small)
                let alignment = align(referenceMTB: referenceMTB, reference: referenceGray, image: gray, profile: profile)
                let smallLongSide = max(smallWidth, smallHeight)
                let scale = Double(max(inputs.reference.width, inputs.reference.height, smallLongSide)) / Double(smallLongSide)
                let sourceTransform = alignment.transform.scaled(by: scale)

                if alignment.status != .lowTexture {
                    if let violation = safetyViolation(
                        sourceTransform,
                        width: max(inputs.reference.width, smallWidth),
                        height: max(inputs.reference.height, smallHeight),
                        profile: profile
                    ) {
                        exclusions.append(HDRFrameExclusionV2(excludedFrameID: source.frame.id, fileName: source.frame.fileName, exclusionReason: violation))
                        analyses.append(FrameAnalysis(source: source, transform: alignment.transform, confidence: alignment.confidence, status: .excluded, gains: [1, 1, 1], mask: nil, motionPercent: 0))
                        continue
                    }
                    if alignment.confidence < profile.minAlignmentConfidence {
                        let reason = String(format: "alignment confidence %.2f < %.2f", alignment.confidence, profile.minAlignmentConfidence)
                        exclusions.append(HDRFrameExclusionV2(excludedFrameID: source.frame.id, fileName: source.frame.fileName, exclusionReason: reason))
                        analyses.append(FrameAnalysis(source: source, transform: alignment.transform, confidence: alignment.confidence, status: .excluded, gains: [1, 1, 1], mask: nil, motionPercent: 0))
                        continue
                    }
                }

                let warpedSmall = warp(small.plane, transform: alignment.transform)
                let warpedGray = luma(RGBXImage(plane: warpedSmall, width: smallWidth, height: smallHeight))

                progress(.normalizing)
                let gains = whiteBalanceGains(reference: referenceSmall.plane, frame: warpedSmall, profile: profile)

                progress(.analyzingMotion)
                let motion = motionMask(reference: referenceGray, aligned: warpedGray, profile: profile)
                if let mask = motion.soft {
                    for index in 0..<unionMotion.count where mask[index] > unionMotion[index] {
                        unionMotion[index] = mask[index]
                    }
                }
                for index in 0..<unionBinary.count where motion.binary[index] != 0 {
                    unionBinary[index] = 1
                }

                if profile.writesLabArtifacts {
                    let name = labAlignedFileName(sequenceIndex: source.frame.sequenceIndex)
                    if let image = makeImage(warpedSmall, width: smallWidth, height: smallHeight),
                       let data = jpegData(image, orientation: inputs.reference.exifOrientation, quality: 0.8),
                       let url = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: name),
                       (try? data.write(to: url, options: .atomic)) != nil {
                        labAligned.append(name)
                    }
                }

                analyses.append(FrameAnalysis(
                    source: source,
                    transform: alignment.transform,
                    confidence: alignment.confidence,
                    status: alignment.status,
                    gains: gains,
                    mask: motion.soft,
                    motionPercent: motion.coveragePercent
                ))
                sampleMemory()
            }

            let included = analyses.filter { $0.status != .excluded }
            guard included.count >= 2 else {
                throw failure(Code.alignmentUnsafe, .sourceRejected, "only EV 0 aligned safely (\(exclusions.count) excluded)")
            }
            let includedEVs = included.map(\.source.ev)
            if !(includedEVs.contains { $0 < -0.25 }) || !(includedEVs.contains { $0 > 0.25 }) {
                warnings.append(Warning.rangeReduced)
            }

            // Motion metrics and deghost decision (on EV 0 geometry).
            progress(.deghosting)
            let pixelCount = Double(unionBinary.count)
            let motionPixels = unionBinary.reduce(0) { $0 + Int($1) }
            let motionCoverage = pixelCount > 0 ? Double(motionPixels) / pixelCount * 100 : 0
            let motionDetected = motionCoverage >= profile.motionDetectedPercent
            let ghostingRisk: HDRGhostingRisk
            if !motionDetected {
                ghostingRisk = motionCoverage > 0 ? .low : .none
            } else if motionCoverage < profile.ghostingMediumPercent {
                ghostingRisk = .low
            } else if motionCoverage < profile.ghostingHighPercent {
                ghostingRisk = .medium
            } else {
                ghostingRisk = .high
            }
            if motionCoverage > profile.ghostingExcessivePercent {
                throw failure(Code.ghostingExcessive, .sourceRejected, String(format: "motion %.1f%%", motionCoverage))
            }
            // Confidence of the EV 0 fallback: share of moving pixels EV 0 itself exposes well.
            var reliable = 0
            if motionPixels > 0 {
                for index in 0..<unionBinary.count where unionBinary[index] != 0 {
                    let value = referenceGray.pixels[index]
                    if value >= 8 && value <= 247 { reliable += 1 }
                }
            }
            let deghostApplied = motionDetected
            let deghostConfidence = motionPixels > 0 ? Double(reliable) / Double(motionPixels) : 1
            if ghostingRisk == .high || (deghostApplied && deghostConfidence < profile.minDeghostConfidence) {
                warnings.append(Warning.ghosting)
            }
            var labMotion: String?
            if profile.writesLabArtifacts,
               let data = grayPNG(unionMotion.map { UInt8(min(255, max(0, $0 * 255))) }, width: smallWidth, height: smallHeight, orientation: inputs.reference.exifOrientation),
               let url = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: labMotionMaskFileName),
               (try? data.write(to: url, options: .atomic)) != nil {
                labMotion = labMotionMaskFileName
            }

            // 3 · working resolution, chosen against the memory actually available.
            try checkDeadline(deadline)
            let sourceLongSide = max(inputs.reference.width, inputs.reference.height, smallWidth, smallHeight)
            let workingMaxPixel = try chooseWorkingMaxPixel(sourceLongSide: sourceLongSide, aspect: Double(smallWidth) / Double(smallHeight), profile: profile)

            progress(.decoding)
            guard let reference = try? decodeRGBX(url: referenceURL, maxPixel: workingMaxPixel) else {
                throw failure(Code.alignmentFailed, .technical, "EV 0 working decode")
            }
            let width = reference.width
            let height = reference.height
            let factor = Double(width) / Double(smallWidth)
            let workingTransforms = included.map { $0.transform.scaled(by: factor) }

            // Safe common crop: computed now so an excessive crop fails before the heavy work.
            let crop = safeCrop(transforms: workingTransforms, width: width, height: height)
            if max(crop.cropPercentX, crop.cropPercentY) > profile.maxCropPercent {
                throw failure(Code.cropExcessive, .sourceRejected, String(format: "crop %.1f%% × %.1f%%", crop.cropPercentX, crop.cropPercentY))
            }
            if max(crop.cropPercentX, crop.cropPercentY) > profile.targetCropPercent {
                warnings.append(Warning.cropAboveTarget)
            }

            // 4 · exposure-aware merge, one decoded frame in memory at a time.
            progress(.merging)
            let accumulator = Accumulator(width: width, height: height)
            let tables = MergeTables(profile: profile)
            let darkest = includedEVs.min() ?? 0
            let brightest = includedEVs.max() ?? 0
            let motionSampler = MaskSampler(width: width, height: height, maskWidth: smallWidth, maskHeight: smallHeight)
            let anyMotion = unionMotion.contains { $0 > 0.001 }

            for (analysis, transform) in zip(included, workingTransforms) {
                try checkDeadline(deadline)
                let isReference = analysis.status == .reference
                let image: PixelPlane<UInt8>
                if isReference {
                    image = reference.plane
                } else {
                    guard let url = CaptureBundleStore.url(for: analysis.source.frame),
                          let decoded = try? decodeRGBX(url: url, maxPixel: workingMaxPixel)
                    else {
                        throw failure(Code.mergeFailed, .technical, "decode \(analysis.source.frame.fileName)")
                    }
                    guard decoded.width == width, decoded.height == height else {
                        throw failure(Code.inputInvalid, .sourceRejected, "working size \(analysis.source.frame.fileName)")
                    }
                    image = warp(decoded.plane, transform: transform)
                }
                let role: MergeRole
                if isReference && abs(darkest - brightest) < 0.01 {
                    role = .middle
                } else if abs(analysis.source.ev - darkest) < 0.01 {
                    role = .darkest
                } else if abs(analysis.source.ev - brightest) < 0.01 {
                    role = .brightest
                } else {
                    role = .middle
                }
                accumulate(
                    image,
                    exposure: Float(pow(2.0, analysis.source.ev)),
                    gains: analysis.gains.map(Float.init),
                    role: role,
                    isReference: isReference,
                    frameMask: isReference ? nil : analysis.mask,
                    unionMask: isReference && anyMotion ? unionMotion : nil,
                    sampler: motionSampler,
                    tables: tables,
                    profile: profile,
                    into: accumulator
                )
                sampleMemory()
            }
            guard accumulator.isFinite() else {
                throw failure(Code.mergeFailed, .technical, "non-finite radiance")
            }

            // 5 · tone map → denoise → sharpen → crop
            try checkDeadline(deadline)
            progress(.toneMapping)
            let toned = toneMap(accumulator, profile: profile)
            sampleMemory()
            progress(.denoising)
            let denoised = denoise(toned, profile: profile)
            progress(.sharpening)
            let sharpened = sharpen(denoised, profile: profile)
            let output = cropped(sharpened, crop: crop)
            let ev0 = cropped(reference.plane, crop: crop)
            sampleMemory()

            // 6 · quality check
            progress(.qualityCheck)
            let hdrStats = imageStats(output)
            let ev0Stats = imageStats(ev0)
            let alignmentConfidence = included.filter { $0.status != .reference }.map(\.confidence).average ?? 1
            let maxRotation = included.map { abs($0.transform.rotationDegrees) }.max() ?? 0
            let geometrySafe = workingTransforms.allSatisfy {
                safetyViolation(
                    $0.scaled(by: Double(sourceLongSide) / Double(max(width, height))),
                    width: sourceLongSide,
                    height: sourceLongSide,
                    profile: profile
                ) == nil
            }
            let quality = qualityChecks(
                QualityInputs(
                    meanLuma: hdrStats.meanLuma,
                    width: output.width,
                    height: output.height,
                    sourceAspect: Double(width) / Double(height),
                    processingLongSide: max(width, height),
                    highlightClip: hdrStats.highlight,
                    shadowClip: hdrStats.shadow,
                    alignmentConfidence: alignmentConfidence,
                    crop: crop,
                    motionCoverage: motionCoverage,
                    ghostingRisk: ghostingRisk,
                    deghostConfidence: deghostConfidence,
                    noise: hdrStats.noise,
                    sharpness: hdrStats.sharpness,
                    geometrySafe: geometrySafe
                ),
                profile: profile
            )
            if let failed = quality.checks.first(where: { $0.result == .fail }) {
                throw failure(quality.failureCode ?? Code.toneMapFailed, quality.failureKind, "\(failed.name): \(failed.detail)")
            }
            for tag in quality.warningTags where !warnings.contains(tag) {
                warnings.append(tag)
            }

            // 7 · write master, preview and thumbnail
            try checkDeadline(deadline)
            progress(.writing)
            let orientation = inputs.reference.exifOrientation
            guard let image = makeImage(output.plane, width: output.width, height: output.height),
                  let masterData = jpegData(image, orientation: orientation, quality: profile.masterJPEGQuality),
                  let previewData = resized(masterData, maxPixel: profile.previewMaxPixel, orientation: orientation, quality: profile.previewJPEGQuality),
                  let thumbnailData = resized(masterData, maxPixel: profile.thumbnailMaxPixel, orientation: orientation, quality: 0.8)
            else {
                throw failure(Code.outputWriteFailed, .technical, "encode")
            }
            guard let masterURL = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: masterFileName),
                  let previewURL = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: previewFileName),
                  let thumbnailURL = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: thumbnailFileName)
            else {
                throw failure(Code.outputWriteFailed, .technical, "bundle path")
            }
            do {
                try masterData.write(to: masterURL, options: .atomic)
                try previewData.write(to: previewURL, options: .atomic)
                try thumbnailData.write(to: thumbnailURL, options: .atomic)
            } catch {
                throw failure(Code.outputWriteFailed, .technical, "write")
            }

            // 8 · READY only after the master exists, reads back, decodes and matches.
            progress(.verifying)
            let checksum = CaptureBundleStore.checksum(masterData)
            guard let stored = try? Data(contentsOf: masterURL),
                  stored.count > 0,
                  stored.count == masterData.count,
                  CaptureBundleStore.checksum(stored) == checksum,
                  let dimensions = pixelDimensions(of: stored),
                  dimensions.width == output.width, dimensions.height == output.height,
                  isDecodable(stored)
            else {
                throw failure(Code.outputVerifyFailed, .technical, "read back")
            }
            sampleMemory()

            let alignments = analyses.map { analysis in
                let transform = analysis.transform.scaled(by: factor)
                return HDRFrameAlignmentV2(
                    frameID: analysis.source.frame.id,
                    fileName: analysis.source.frame.fileName,
                    evLabel: analysis.source.frame.evLabel,
                    relativeEV: analysis.source.ev,
                    translationX: transform.translationX,
                    translationY: transform.translationY,
                    rotationDegrees: transform.rotationDegrees,
                    scaleDelta: transform.scaleDelta,
                    alignmentConfidence: analysis.confidence,
                    alignmentStatus: analysis.status,
                    whiteBalanceGains: analysis.gains,
                    motionCoveragePercent: analysis.motionPercent
                )
            }

            let record = HDRMasterV2Record(
                assetID: UUID(),
                captureID: captureID,
                clientCaptureID: manifest.clientCaptureID,
                pipelineVersion: pipelineVersion,
                profileVersion: profile.version,
                inputFrameIDs: included.map(\.source.frame.id),
                excludedFrameIDs: exclusions.map(\.excludedFrameID),
                referenceFrameID: inputs.reference.id,
                referenceFileName: inputs.reference.fileName,
                fileName: masterFileName,
                previewFileName: previewFileName,
                thumbnailFileName: thumbnailFileName,
                width: output.width,
                height: output.height,
                exifOrientation: orientation,
                orientation: inputs.reference.orientation,
                fileSize: stored.count,
                previewFileSize: previewData.count,
                checksum: checksum,
                processingDuration: Date().timeIntervalSince(started),
                processingWidth: width,
                processingHeight: height,
                peakMemoryMB: peakMemory,
                alignments: alignments,
                exclusions: exclusions,
                alignmentConfidence: alignmentConfidence,
                maxRotationCorrection: maxRotation,
                crop: crop,
                cropPercentX: crop.cropPercentX,
                cropPercentY: crop.cropPercentY,
                motionDetected: motionDetected,
                motionCoverage: motionCoverage,
                ghostingRisk: ghostingRisk,
                deghostApplied: deghostApplied,
                deghostConfidence: deghostConfidence,
                ev0HighlightClipping: ev0Stats.highlight,
                ev0ShadowClipping: ev0Stats.shadow,
                highlightClipping: hdrStats.highlight,
                shadowClipping: hdrStats.shadow,
                noiseEstimate: hdrStats.noise,
                sharpnessEstimate: hdrStats.sharpness,
                qualityResult: quality.result,
                qualityChecks: quality.checks,
                warnings: warnings,
                labAlignedFileNames: labAligned,
                labMotionMaskFileName: labMotion,
                createdAt: .now
            )
            try HDRMasterV2Store.write(record)
            progress(.done)
            return .success(record)
        } catch let failure as HDRProcessingFailure {
            return .failure(failure)
        } catch {
            return .failure(failure(Code.mergeFailed, .technical, "unexpected"))
        }
    }

    private static func failure(_ code: String, _ kind: HDRProcessingFailure.Kind, _ detail: String) -> HDRProcessingFailure {
        HDRProcessingFailure(code: code, kind: kind, detail: detail)
    }

    private static func checkDeadline(_ deadline: Date) throws {
        if Date() > deadline { throw failure(Code.timeout, .technical, "deadline") }
    }

    // MARK: - 1 · Validate

    struct SourceFrame: Sendable {
        var frame: CaptureFrame
        /// Measured exposure relative to EV 0, in EV.
        var ev: Double
    }

    struct Inputs: Sendable {
        var reference: CaptureFrame
        /// EV 0 first, then ladder order.
        var frames: [SourceFrame]
        var warnings: [String]
    }

    /// Real files only: persisted, checksum-verified from disk, unique, one attempt, one lens,
    /// one geometry, one orientation, with EV 0 and at least one darker and one brighter frame.
    static func validate(_ manifest: CaptureManifest, profile: HDRProcessingProfile) throws -> Inputs {
        guard manifest.state.isValid else {
            throw failure(Code.inputInvalid, .sourceRejected, "manifest \(manifest.state.devLabel)")
        }
        let frames = manifest.orderedFrames
        guard let reference = frames.first(where: \.isReferenceExposure) else {
            throw failure(Code.inputInvalid, .sourceRejected, "no EV 0")
        }
        guard frames.allSatisfy({ $0.clientCaptureID == manifest.clientCaptureID }) else {
            throw failure(Code.inputInvalid, .sourceRejected, "frames from another attempt")
        }
        guard frames.allSatisfy({ $0.orientation == reference.orientation && $0.exifOrientation == reference.exifOrientation }),
              reference.orientation == manifest.orientation
        else {
            throw failure(Code.inputInvalid, .sourceRejected, "orientation mismatch")
        }
        guard frames.allSatisfy({ $0.lensType == reference.lensType && $0.cameraID == reference.cameraID }) else {
            throw failure(Code.inputInvalid, .sourceRejected, "lens mismatch")
        }
        guard frames.allSatisfy({ $0.width == reference.width && $0.height == reference.height }) else {
            throw failure(Code.inputInvalid, .sourceRejected, "dimension mismatch")
        }
        for frame in frames {
            guard let data = CaptureBundleStore.loadData(frame), !data.isEmpty,
                  CaptureBundleStore.checksum(data) == frame.checksum
            else {
                throw failure(Code.inputInvalid, .technical, "file or checksum \(frame.fileName)")
            }
        }

        var seen: Set<String> = []
        let unique = frames.filter { seen.insert($0.checksum).inserted }
        let relative = BracketAuditor.relativeExposures(unique)
        let evs = unique.map { relative[$0.id] ?? $0.requestedEV }
        guard evs.contains(where: { $0 < -0.25 }), evs.contains(where: { $0 > 0.25 }) else {
            throw failure(Code.inputInvalid, .sourceRejected, "needs a darker and a brighter exposure than EV 0")
        }

        var warnings: [String] = []
        if manifest.captureProfile == .full9 && unique.count < 9 {
            warnings.append("\(Warning.full9Incomplete) \(unique.count)/9")
        }
        let ordered = unique.sorted { lhs, rhs in
            if lhs.id == reference.id { return true }
            if rhs.id == reference.id { return false }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return Inputs(
            reference: reference,
            frames: ordered.map { SourceFrame(frame: $0, ev: relative[$0.id] ?? $0.requestedEV) },
            warnings: warnings
        )
    }

    // MARK: - 2 · Align (directly to EV 0)

    struct FrameAnalysis {
        var source: SourceFrame
        /// At alignment resolution.
        var transform: HDRTransformV2
        var confidence: Double
        var status: HDRAlignmentStatus
        var gains: [Double]
        var mask: [Float]?
        var motionPercent: Double
    }

    struct AlignmentResult: Sendable {
        var transform: HDRTransformV2
        var confidence: Double
        var texturedFraction: Double
        var status: HDRAlignmentStatus
    }

    /// Median-threshold bitmap of EV 0: exposure-invariant, so frames of any EV compare to it.
    struct MTBReference: Sendable {
        var width: Int
        var height: Int
        var bits: [UInt8]
        var valid: [UInt8]
        var texturedFraction: Double

        static let band: Float = 4

        init(_ image: GrayImage) {
            width = image.width
            height = image.height
            let median = Float(HDRPipelineV2.median(image.pixels))
            bits = image.pixels.map { Float($0) > median ? 1 : 0 }
            valid = image.pixels.map { abs(Float($0) - median) > Self.band ? 1 : 0 }
            let textured = valid.reduce(0) { $0 + Int($1) }
            texturedFraction = image.pixels.isEmpty ? 0 : Double(textured) / Double(image.pixels.count)
        }
    }

    /// Translation (pyramid MTB) first, then small rotation and scale by coordinate descent on
    /// the bitmap mismatch rate, sampled bilinearly for sub-pixel precision. Never projective.
    static func align(
        referenceMTB: MTBReference,
        reference: GrayImage,
        image: GrayImage,
        profile: HDRProcessingProfile
    ) -> AlignmentResult {
        let imageMedian = Float(median(image.pixels))
        let texturedImage = Double(image.pixels.reduce(0) { $0 + (abs(Float($1) - imageMedian) > MTBReference.band ? 1 : 0) })
            / Double(max(1, image.pixels.count))
        let textured = min(referenceMTB.texturedFraction, texturedImage)
        guard textured >= profile.minTexturedFraction else {
            return AlignmentResult(transform: .identity, confidence: 0, texturedFraction: textured, status: .lowTexture)
        }

        let pixelCount = image.width * image.height
        let stride = max(1, Int((Double(pixelCount) / 120_000).squareRoot().rounded(.up)))
        func cost(_ transform: HDRTransformV2) -> Double {
            mismatch(reference: referenceMTB, image: image, imageMedian: imageMedian, transform: transform, stride: stride)
        }

        let coarse = MedianThresholdAligner.align(reference: reference, image: image)
        var best = HDRTransformV2(translationX: Double(coarse.dx), translationY: Double(coarse.dy), rotationDegrees: 0, scaleDelta: 0)
        var bestCost = cost(best)
        let identityCost = cost(.identity)
        if identityCost < bestCost {
            best = .identity
            bestCost = identityCost
        }

        func search(_ candidates: [HDRTransformV2]) {
            for candidate in candidates {
                let value = cost(candidate)
                if value < bestCost - 1e-9 {
                    bestCost = value
                    best = candidate
                }
            }
        }
        func translations(radius: Double, step: Double) -> [HDRTransformV2] {
            var output: [HDRTransformV2] = []
            var dy = -radius
            while dy <= radius + 1e-9 {
                var dx = -radius
                while dx <= radius + 1e-9 {
                    if dx != 0 || dy != 0 {
                        var candidate = best
                        candidate.translationX += dx
                        candidate.translationY += dy
                        output.append(candidate)
                    }
                    dx += step
                }
                dy += step
            }
            return output
        }
        func rotations(center: Double, radius: Double, step: Double) -> [HDRTransformV2] {
            Swift.stride(from: center - radius, through: center + radius + 1e-9, by: step).map {
                var candidate = best
                candidate.rotationDegrees = $0
                return candidate
            }
        }
        func scales(radius: Double, step: Double) -> [HDRTransformV2] {
            Swift.stride(from: -radius, through: radius + 1e-9, by: step).map {
                var candidate = best
                candidate.scaleDelta = $0
                return candidate
            }
        }

        search(translations(radius: 2, step: 1))
        search(rotations(center: 0, radius: profile.rotationSearchDegrees, step: 0.25))
        search(translations(radius: 2, step: 1))
        search(rotations(center: best.rotationDegrees, radius: 0.25, step: 0.05))
        search(scales(radius: profile.scaleSearchDelta, step: 0.005))
        search(translations(radius: 1, step: 0.5))
        search(rotations(center: best.rotationDegrees, radius: 0.1, step: 0.025))
        search(translations(radius: 0.5, step: 0.25))

        // Confidence: how distinct the optimum is against clearly wrong placements.
        let offset = max(3, Double(image.width) * 0.03)
        let wrong = [(offset, 0.0), (-offset, 0.0), (0.0, offset), (0.0, -offset)].map { dx, dy -> Double in
            var candidate = best
            candidate.translationX += dx
            candidate.translationY += dy
            return cost(candidate)
        }
        let baseline = wrong.reduce(0, +) / Double(wrong.count)
        let confidence = baseline > 0 ? max(0, min(1, 1 - bestCost / baseline)) : 0
        return AlignmentResult(transform: best, confidence: confidence, texturedFraction: textured, status: .aligned)
    }

    /// Share of comparable textured pixels whose bitmap bit disagrees, with the image sampled at
    /// `transform(reference pixel)`.
    static func mismatch(
        reference: MTBReference,
        image: GrayImage,
        imageMedian: Float,
        transform: HDRTransformV2,
        stride: Int
    ) -> Double {
        let width = reference.width
        let height = reference.height
        guard image.width == width, image.height == height, width > 1, height > 1 else { return 1 }
        let coefficients = affine(transform)
        let a = coefficients.a
        let b = coefficients.b
        let cx = Float(width - 1) / 2
        let cy = Float(height - 1) / 2
        let tx = Float(transform.translationX)
        let ty = Float(transform.translationY)
        let maxX = Float(width - 1)
        let maxY = Float(height - 1)
        let band = MTBReference.band
        var errors = 0
        var compared = 0
        image.pixels.withUnsafeBufferPointer { pixels in
            reference.bits.withUnsafeBufferPointer { bits in
                reference.valid.withUnsafeBufferPointer { valid in
                    guard let p = pixels.baseAddress else { return }
                    var y = 0
                    while y < height {
                        let dy = Float(y) - cy
                        var x = 0
                        while x < width {
                            let index = y * width + x
                            if valid[index] != 0 {
                                let dx = Float(x) - cx
                                let sx = a * dx - b * dy + cx + tx
                                let sy = b * dx + a * dy + cy + ty
                                if sx >= 0, sy >= 0, sx <= maxX, sy <= maxY {
                                    let value = bilinear(p, width, height, sx, sy)
                                    if abs(value - imageMedian) > band {
                                        compared += 1
                                        let bit: UInt8 = value > imageMedian ? 1 : 0
                                        if bit != bits[index] { errors += 1 }
                                    }
                                }
                            }
                            x += stride
                        }
                        y += stride
                    }
                }
            }
        }
        guard compared >= 64 else { return 1 }
        return Double(errors) / Double(compared)
    }

    /// `nil` when the transform is within the conservative limits; otherwise why it is unsafe.
    /// `transform` is at the source resolution of a `width × height` frame.
    static func safetyViolation(
        _ transform: HDRTransformV2,
        width: Int,
        height: Int,
        profile: HDRProcessingProfile
    ) -> String? {
        let maxTranslation = profile.maxTranslationPercent / 100 * Double(max(width, height))
        if abs(transform.translationX) > maxTranslation || abs(transform.translationY) > maxTranslation {
            return String(format: "translation %.0f, %.0f px exceeds %.0f px", transform.translationX, transform.translationY, maxTranslation)
        }
        if abs(transform.rotationDegrees) > profile.maxRotationDegrees {
            return String(format: "rotation %.2f° exceeds %.2f°", transform.rotationDegrees, profile.maxRotationDegrees)
        }
        if abs(transform.scaleDelta) > profile.maxScaleDelta {
            return String(format: "scale %.3f exceeds %.3f", transform.scaleDelta, profile.maxScaleDelta)
        }
        return nil
    }

    private static func affine(_ transform: HDRTransformV2) -> (a: Float, b: Float) {
        let theta = transform.rotationDegrees * .pi / 180
        let scale = 1 + transform.scaleDelta
        return (Float(scale * cos(theta)), Float(scale * sin(theta)))
    }

    @inline(__always)
    private static func bilinear(_ p: UnsafePointer<UInt8>, _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> Float {
        let x0 = Int(x)
        let y0 = Int(y)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let top = Float(p[y0 * width + x0]) * (1 - fx) + Float(p[y0 * width + x1]) * fx
        let bottom = Float(p[y1 * width + x0]) * (1 - fx) + Float(p[y1 * width + x1]) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// aligned(x, y) = source(T(x, y)), bilinear, edges extended (the safe crop removes them).
    static func warp(_ source: PixelPlane<UInt8>, transform: HDRTransformV2) -> PixelPlane<UInt8> {
        guard transform != .identity else { return source }
        let width = source.width
        let height = source.height
        let channels = source.channels
        let output = PixelPlane<UInt8>(width: width, height: height, channels: channels)
        let coefficients = affine(transform)
        let a = coefficients.a
        let b = coefficients.b
        let cx = Float(width - 1) / 2
        let cy = Float(height - 1) / 2
        let tx = Float(transform.translationX)
        let ty = Float(transform.translationY)
        let maxX = Float(width - 1)
        let maxY = Float(height - 1)
        let colour = min(channels, 3)
        let src = source.pointer
        for y in 0..<height {
            let dy = Float(y) - cy
            var sx = -a * cx - b * dy + cx + tx
            var sy = -b * cx + a * dy + cy + ty
            let row = output.pointer + y * width * channels
            for x in 0..<width {
                let px = min(max(sx, 0), maxX)
                let py = min(max(sy, 0), maxY)
                let x0 = Int(px)
                let y0 = Int(py)
                let x1 = min(x0 + 1, width - 1)
                let y1 = min(y0 + 1, height - 1)
                let fx = px - Float(x0)
                let fy = py - Float(y0)
                let w00 = (1 - fx) * (1 - fy)
                let w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy
                let w11 = fx * fy
                let i00 = (y0 * width + x0) * channels
                let i10 = (y0 * width + x1) * channels
                let i01 = (y1 * width + x0) * channels
                let i11 = (y1 * width + x1) * channels
                let target = row + x * channels
                for c in 0..<colour {
                    let value = Float(src[i00 + c]) * w00 + Float(src[i10 + c]) * w10
                        + Float(src[i01 + c]) * w01 + Float(src[i11 + c]) * w11
                    target[c] = UInt8(min(255, value + 0.5))
                }
                if channels == 4 { target[3] = 255 }
                sx += a
                sy += b
            }
        }
        return output
    }

    // MARK: - Normalize (colour drift towards EV 0)

    /// Per-channel gains that bring a frame's colour balance to EV 0's, measured on pixels both
    /// expose well. Clamped: a conservative correction that keeps warm interior light warm.
    static func whiteBalanceGains(reference: PixelPlane<UInt8>, frame: PixelPlane<UInt8>, profile: HDRProcessingProfile) -> [Double] {
        let count = reference.width * reference.height
        guard frame.count == reference.count, count > 0 else { return [1, 1, 1] }
        let table = (0..<256).map { Double(powf(Float($0) / 255, profile.gamma)) }
        var referenceSum = [0.0, 0.0, 0.0]
        var frameSum = [0.0, 0.0, 0.0]
        var used = 0
        var index = 0
        let step = max(1, count / 200_000)
        while index < count {
            let r = reference.pointer + index * 4
            let f = frame.pointer + index * 4
            let rMax = max(r[0], r[1], r[2])
            let rMin = min(r[0], r[1], r[2])
            let fMax = max(f[0], f[1], f[2])
            let fMin = min(f[0], f[1], f[2])
            if rMin >= 20, rMax <= 235, fMin >= 20, fMax <= 235 {
                for c in 0..<3 {
                    referenceSum[c] += table[Int(r[c])]
                    frameSum[c] += table[Int(f[c])]
                }
                used += 1
            }
            index += step
        }
        guard used >= max(50, count / step / 200), referenceSum[1] > 0, frameSum[1] > 0 else { return [1, 1, 1] }
        let limit = profile.whiteBalanceMaxCorrection
        return (0..<3).map { c in
            guard frameSum[c] > 0 else { return 1 }
            let gain = (referenceSum[c] / referenceSum[1]) / (frameSum[c] / frameSum[1])
            return min(1 + limit, max(1 - limit, gain))
        }
    }

    // MARK: - Motion analysis

    struct MotionResult {
        /// Soft mask in EV 0 geometry, 0…1. `nil` when nothing moved.
        var soft: [Float]?
        var binary: [UInt8]
        var coveragePercent: Double
    }

    /// Compares an aligned exposure with EV 0 through their measured comparametric curve (the
    /// median frame value for each EV 0 value), so the camera's own tone curve is not mistaken
    /// for motion. Only pixels both frames expose usefully are judged.
    static func motionMask(reference: GrayImage, aligned: GrayImage, profile: HDRProcessingProfile) -> MotionResult {
        let count = reference.pixels.count
        guard aligned.pixels.count == count, count > 0 else {
            return MotionResult(soft: nil, binary: [UInt8](repeating: 0, count: count), coveragePercent: 0)
        }
        var histogram = [Int](repeating: 0, count: 256 * 256)
        var totals = [Int](repeating: 0, count: 256)
        for index in 0..<count {
            let r = Int(reference.pixels[index])
            let f = Int(aligned.pixels[index])
            guard r >= 4, r <= 251, f >= 4, f <= 251 else { continue }
            histogram[r * 256 + f] += 1
            totals[r] += 1
        }
        var curve = [Float](repeating: .nan, count: 256)
        for r in 0..<256 where totals[r] >= 16 {
            var cumulative = 0
            for f in 0..<256 {
                cumulative += histogram[r * 256 + f]
                if cumulative * 2 >= totals[r] {
                    curve[r] = Float(f)
                    break
                }
            }
        }
        let known = (0..<256).filter { !curve[$0].isNaN }
        guard let first = known.first, let last = known.last else {
            return MotionResult(soft: nil, binary: [UInt8](repeating: 0, count: count), coveragePercent: 0)
        }
        for r in 0..<256 where curve[r].isNaN {
            if r < first { curve[r] = curve[first]; continue }
            if r > last { curve[r] = curve[last]; continue }
            let lower = known.last { $0 < r } ?? first
            let upper = known.first { $0 > r } ?? last
            let t = Float(r - lower) / Float(max(1, upper - lower))
            curve[r] = curve[lower] + (curve[upper] - curve[lower]) * t
        }
        // Enforce monotonic (a tone curve never falls).
        for r in 1..<256 where curve[r] < curve[r - 1] { curve[r] = curve[r - 1] }
        let threshold = profile.motionThreshold * 255
        let limits = (0..<256).map { r -> Float in
            let slope = (curve[min(255, r + 6)] - curve[max(0, r - 6)]) / 12
            return threshold * max(1, slope)
        }

        var binary = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let r = Int(reference.pixels[index])
            let f = aligned.pixels[index]
            let predicted = curve[r]
            guard r >= 8, r <= 247, predicted >= 10, predicted <= 245, f >= 4, f <= 251 else { continue }
            if abs(Float(f) - predicted) > limits[r] { binary[index] = 1 }
        }
        // Opening removes isolated noise and edge flicker; dilation then covers the object's rim.
        let width = reference.width
        let height = reference.height
        let opened = morphology(morphology(binary, width: width, height: height, radius: 1, dilate: false), width: width, height: height, radius: 1, dilate: true)
        let moving = opened.reduce(0) { $0 + Int($1) }
        guard moving > 0 else {
            return MotionResult(soft: nil, binary: opened, coveragePercent: 0)
        }
        let grown = morphology(opened, width: width, height: height, radius: profile.motionDilation, dilate: true)
        let soft = boxBlur(grown.map { Float($0) }, width: width, height: height, radius: 2)
        return MotionResult(soft: soft, binary: opened, coveragePercent: Double(moving) / Double(count) * 100)
    }

    /// Separable square min (erode) / max (dilate) filter.
    static func morphology(_ input: [UInt8], width: Int, height: Int, radius: Int, dilate: Bool) -> [UInt8] {
        guard radius > 0 else { return input }
        var horizontal = [UInt8](repeating: 0, count: input.count)
        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = dilate ? 0 : 1
                for k in max(0, x - radius)...min(width - 1, x + radius) {
                    let v = input[y * width + k]
                    value = dilate ? max(value, v) : min(value, v)
                }
                horizontal[y * width + x] = value
            }
        }
        var output = [UInt8](repeating: 0, count: input.count)
        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = dilate ? 0 : 1
                for k in max(0, y - radius)...min(height - 1, y + radius) {
                    let v = horizontal[k * width + x]
                    value = dilate ? max(value, v) : min(value, v)
                }
                output[y * width + x] = value
            }
        }
        return output
    }

    static func boxBlur(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return input }
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                let lower = max(0, x - radius)
                let upper = min(width - 1, x + radius)
                for k in lower...upper { sum += input[y * width + k] }
                horizontal[y * width + x] = sum / Float(upper - lower + 1)
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let lower = max(0, y - radius)
            let upper = min(height - 1, y + radius)
            for x in 0..<width {
                var sum: Float = 0
                for k in lower...upper { sum += horizontal[k * width + x] }
                output[y * width + x] = sum / Float(upper - lower + 1)
            }
        }
        return output
    }

    // MARK: - Merge

    enum MergeRole {
        /// Darkest exposure: its bright pixels are the trustworthy highlight (window) data.
        case darkest
        /// Brightest exposure: its dark pixels are the cleanest shadow data.
        case brightest
        /// Mid exposures carry the tonal continuity between them.
        case middle
    }

    final class Accumulator {
        let width: Int
        let height: Int
        let red: PixelPlane<Float>
        let green: PixelPlane<Float>
        let blue: PixelPlane<Float>
        let weight: PixelPlane<Float>

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            red = PixelPlane(width: width, height: height)
            green = PixelPlane(width: width, height: height)
            blue = PixelPlane(width: width, height: height)
            weight = PixelPlane(width: width, height: height)
            for plane in [red, green, blue, weight] {
                vDSP_vclr(plane.pointer, 1, vDSP_Length(plane.count))
            }
        }

        func isFinite() -> Bool {
            var index = 0
            let count = width * height
            while index < count {
                if !red.pointer[index].isFinite || !weight.pointer[index].isFinite || weight.pointer[index] <= 0 { return false }
                index += 97
            }
            return true
        }
    }

    struct MergeTables {
        var linear: [Float]

        init(profile: HDRProcessingProfile) {
            linear = (0..<256).map { powf(Float($0) / 255, profile.gamma) }
        }
    }

    /// Bilinear lookup of a low-resolution mask at full resolution.
    struct MaskSampler {
        var x0: [Int]
        var x1: [Int]
        var fx: [Float]
        var y0: [Int]
        var y1: [Int]
        var fy: [Float]
        var maskWidth: Int

        init(width: Int, height: Int, maskWidth: Int, maskHeight: Int) {
            self.maskWidth = maskWidth
            func axis(_ size: Int, _ maskSize: Int) -> ([Int], [Int], [Float]) {
                var lower: [Int] = []
                var upper: [Int] = []
                var fraction: [Float] = []
                let ratio = Float(maskSize) / Float(max(1, size))
                for i in 0..<size {
                    let position = min(max((Float(i) + 0.5) * ratio - 0.5, 0), Float(maskSize - 1))
                    let base = Int(position)
                    lower.append(base)
                    upper.append(min(base + 1, maskSize - 1))
                    fraction.append(position - Float(base))
                }
                return (lower, upper, fraction)
            }
            (x0, x1, fx) = axis(width, maskWidth)
            (y0, y1, fy) = axis(height, maskHeight)
        }
    }

    /// Adds one aligned exposure. radiance = Σ w·linear·gain / Σ w·exposure, with an
    /// exposure-aware hat weight and penalties for clipped, noisy and moving pixels.
    static func accumulate(
        _ image: PixelPlane<UInt8>,
        exposure: Float,
        gains: [Float],
        role: MergeRole,
        isReference: Bool,
        frameMask: [Float]?,
        unionMask: [Float]?,
        sampler: MaskSampler,
        tables: MergeTables,
        profile: HDRProcessingProfile,
        into accumulator: Accumulator
    ) {
        let width = accumulator.width
        let height = accumulator.height
        let clip = profile.clipLevel
        let clippedFactor = profile.clippedWeightFactor
        let noiseFloor = profile.noiseFloorLevel
        let floor = profile.weightFloor
        let strength = profile.deghostStrength
        let gainR = gains.count == 3 ? gains[0] : 1
        let gainG = gains.count == 3 ? gains[1] : 1
        let gainB = gains.count == 3 ? gains[2] : 1
        let mask = frameMask ?? unionMask
        tables.linear.withUnsafeBufferPointer { lut in
            for y in 0..<height {
                let my0 = sampler.y0[y] * sampler.maskWidth
                let my1 = sampler.y1[y] * sampler.maskWidth
                let fy = sampler.fy[y]
                for x in 0..<width {
                    let index = y * width + x
                    let p = image.pointer + index * 4
                    let r = Int(p[0])
                    let g = Int(p[1])
                    let b = Int(p[2])
                    let m = Float(max(r, g, b)) / 255
                    var t = 2 * m - 1
                    switch role {
                    case .darkest: t = min(t, 0)
                    case .brightest: t = max(t, 0)
                    case .middle: break
                    }
                    let t2 = t * t
                    let t4 = t2 * t2
                    var w = 1 - t4 * t4 * t4
                    if role != .darkest && m >= clip { w *= clippedFactor }
                    if role != .brightest && m < noiseFloor {
                        let q = m / noiseFloor
                        w *= q * q
                    }
                    if let mask {
                        let top = mask[my0 + sampler.x0[x]] * (1 - sampler.fx[x]) + mask[my0 + sampler.x1[x]] * sampler.fx[x]
                        let bottom = mask[my1 + sampler.x0[x]] * (1 - sampler.fx[x]) + mask[my1 + sampler.x1[x]] * sampler.fx[x]
                        let motion = top * (1 - fy) + bottom * fy
                        if isReference {
                            // Deghost: wherever anything moved, EV 0's real pixels lead.
                            w = max(w, motion)
                        } else {
                            w *= 1 - strength * motion
                        }
                    }
                    w = max(w, floor)
                    accumulator.red.pointer[index] += w * lut[r] * gainR
                    accumulator.green.pointer[index] += w * lut[g] * gainG
                    accumulator.blue.pointer[index] += w * lut[b] * gainB
                    accumulator.weight.pointer[index] += w * exposure
                }
            }
        }
    }

    // MARK: - Tone map

    /// Natural architectural rendering: luminance-only extended Reinhard (no hue shifts),
    /// restrained edge-attenuated local contrast (no halos), a real black point and clean whites.
    static func toneMap(_ accumulator: Accumulator, profile: HDRProcessingProfile) -> PixelPlane<UInt8> {
        let width = accumulator.width
        let height = accumulator.height
        let count = width * height
        let red = accumulator.red.pointer
        let green = accumulator.green.pointer
        let blue = accumulator.blue.pointer
        let luminance = accumulator.weight.pointer
        let key = profile.keyScale

        // Radiance, in place; the weight plane becomes luminance.
        for index in 0..<count {
            let inverse = key / max(luminance[index], 1e-12)
            red[index] *= inverse
            green[index] *= inverse
            blue[index] *= inverse
            luminance[index] = 0.2126 * red[index] + 0.7152 * green[index] + 0.0722 * blue[index]
        }

        let samples = sampled(luminance, count: count)
        let white = max(1, percentile(samples, profile.whitePercentile))
        let inverseWhiteSquared = 1 / (white * white)

        // Global curve.
        let tone = PixelPlane<Float>(width: width, height: height)
        for index in 0..<count {
            let y = luminance[index]
            tone.pointer[index] = y * (1 + y * inverseWhiteSquared) / (1 + y)
        }

        // Restrained local contrast against a coarse base layer.
        let factor = 8
        let baseWidth = max(1, width / factor)
        let baseHeight = max(1, height / factor)
        var base = [Float](repeating: 0, count: baseWidth * baseHeight)
        for by in 0..<baseHeight {
            for bx in 0..<baseWidth {
                var sum: Float = 0
                var n: Float = 0
                for y in (by * factor)..<min(height, by * factor + factor) {
                    for x in (bx * factor)..<min(width, bx * factor + factor) {
                        sum += tone.pointer[y * width + x]
                        n += 1
                    }
                }
                base[by * baseWidth + bx] = n > 0 ? sum / n : 0
            }
        }
        let radius = max(1, Int(profile.localContrastRadiusFraction * Double(max(width, height)) / Double(factor)))
        base = boxBlur(base, width: baseWidth, height: baseHeight, radius: radius)
        let sampler = MaskSampler(width: width, height: height, maskWidth: baseWidth, maskHeight: baseHeight)
        let gain = profile.localContrast
        let limit = profile.localContrastLimit
        for y in 0..<height {
            let row0 = sampler.y0[y] * baseWidth
            let row1 = sampler.y1[y] * baseWidth
            let fy = sampler.fy[y]
            for x in 0..<width {
                let top = base[row0 + sampler.x0[x]] * (1 - sampler.fx[x]) + base[row0 + sampler.x1[x]] * sampler.fx[x]
                let bottom = base[row1 + sampler.x0[x]] * (1 - sampler.fx[x]) + base[row1 + sampler.x1[x]] * sampler.fx[x]
                let baseValue = top * (1 - fy) + bottom * fy
                let index = y * width + x
                let detail = tone.pointer[index] - baseValue
                let ratio = detail / 0.08
                // Large steps (window frames) get almost no boost: that is where halos are born.
                let attenuated = gain / (1 + ratio * ratio)
                let delta = min(limit, max(-limit, attenuated * detail))
                tone.pointer[index] = max(0, tone.pointer[index] + delta)
            }
        }

        // Black point → real blacks.
        let toneSamples = sampled(tone.pointer, count: count)
        // Capped to a few encoded levels: it removes flare and noise, never real shadow detail.
        let blackCap = powf(profile.maxBlackPointLevels / 255, profile.gamma)
        let blackPoint = min(blackCap, percentile(toneSamples, profile.blackPercentile) * profile.blackPointStrength)
        let blackScale = 1 / max(0.01, 1 - blackPoint)

        // Display encoding with a gentle S-curve, baked into one table.
        // 64K entries: a coarse table quantises deep shadows (index 1 of 4096 is already 6/255).
        let tableSize = 65_536
        let contrast = profile.contrast
        let exponent = 1 / profile.gamma
        let contrastToe = profile.contrastToe
        let encode: [UInt8] = (0..<tableSize).map { i in
            let v = powf(Float(i) / Float(tableSize - 1), exponent)
            let toe = min(1, v / max(0.001, contrastToe))
            let s = v + 4 * contrast * (2 * v - 1) * v * (1 - v) * toe * toe
            return UInt8(min(255, max(0, s * 255 + 0.5)))
        }
        let saturation = profile.saturation
        let desaturation = profile.highlightDesaturation
        let knee = profile.highlightKnee
        let shoulder = max(0.001, profile.highlightCeiling - knee)
        let lift = min(2.5, max(0, profile.shadowLift))
        let shadowToe = max(1e-4, profile.shadowToe)
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        encode.withUnsafeBufferPointer { table in
            for index in 0..<count {
                let y = luminance[index]
                var mapped = max(0, (tone.pointer[index] - blackPoint) * blackScale)
                // Highlight shoulder: slope 1 at the knee, asymptotic to the ceiling. Keeps window
                // gradations instead of saturating them at 255 after contrast and sharpening.
                if mapped > knee {
                    mapped = knee + shoulder * (1 - expf(-(mapped - knee) / shoulder))
                } else if mapped < shadowToe {
                    // Monotone toe (lift < 3), slope 1 at the toe: opens deep shadows naturally.
                    let u = 1 - mapped / shadowToe
                    mapped *= 1 + lift * u * u
                }
                let highlight = min(1, max(0, (mapped - knee) / shoulder))
                let effective = saturation * (1 - desaturation * highlight * highlight * (3 - 2 * highlight))
                let target = output.pointer + index * 4
                if y > 1e-9 {
                    let channels = (red[index] / y, green[index] / y, blue[index] / y)
                    let r = min(1, max(0, mapped * (1 + effective * (channels.0 - 1))))
                    let g = min(1, max(0, mapped * (1 + effective * (channels.1 - 1))))
                    let b = min(1, max(0, mapped * (1 + effective * (channels.2 - 1))))
                    target[0] = table[Int(r * Float(tableSize - 1) + 0.5)]
                    target[1] = table[Int(g * Float(tableSize - 1) + 0.5)]
                    target[2] = table[Int(b * Float(tableSize - 1) + 0.5)]
                } else {
                    target[0] = 0
                    target[1] = 0
                    target[2] = 0
                }
                target[3] = 255
            }
        }
        return output
    }

    private static func sampled(_ pointer: UnsafeMutablePointer<Float>, count: Int) -> [Float] {
        let step = max(1, count / 150_000)
        var samples: [Float] = []
        samples.reserveCapacity(count / step + 1)
        var index = 0
        while index < count {
            let value = pointer[index]
            if value.isFinite { samples.append(value) }
            index += step
        }
        samples.sort()
        return samples
    }

    private static func percentile(_ sorted: [Float], _ fraction: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))]
    }

    // MARK: - Denoise & sharpen

    /// 3 × 3 edge-aware (luminance-range) smoothing after the merge, stronger in shadows where
    /// noise lives. Edges and texture differing by more than a few levels are left alone.
    static func denoise(_ image: PixelPlane<UInt8>, profile: HDRProcessingProfile) -> PixelPlane<UInt8> {
        let width = image.width
        let height = image.height
        guard profile.denoiseStrength > 0, width > 2, height > 2 else { return image }
        let lumaPlane = lumaValues(image)
        let edge = max(1, profile.denoiseEdgeLevels)
        let weights = (0..<256).map { d -> Float in
            let x = Float(d) / edge
            return expf(-x * x)
        }
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        memcpy(output.pointer, image.pointer, image.count)
        let strength = profile.denoiseStrength
        let src = image.pointer
        weights.withUnsafeBufferPointer { w in
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    let center = Int(lumaPlane[index])
                    var sumR: Float = 0
                    var sumG: Float = 0
                    var sumB: Float = 0
                    var total: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let neighbour = index + dy * width + dx
                            let weight = w[abs(Int(lumaPlane[neighbour]) - center)]
                            let p = src + neighbour * 4
                            sumR += weight * Float(p[0])
                            sumG += weight * Float(p[1])
                            sumB += weight * Float(p[2])
                            total += weight
                        }
                    }
                    let amount = strength * (0.5 + 0.5 * (1 - Float(center) / 255))
                    let p = src + index * 4
                    let q = output.pointer + index * 4
                    q[0] = UInt8(min(255, max(0, Float(p[0]) + amount * (sumR / total - Float(p[0])) + 0.5)))
                    q[1] = UInt8(min(255, max(0, Float(p[1]) + amount * (sumG / total - Float(p[1])) + 0.5)))
                    q[2] = UInt8(min(255, max(0, Float(p[2]) + amount * (sumB / total - Float(p[2])) + 0.5)))
                }
            }
        }
        return output
    }

    /// Subtle luminance unsharp mask: ignores sub-threshold noise and caps the overshoot so
    /// edges never grow halos.
    static func sharpen(_ image: PixelPlane<UInt8>, profile: HDRProcessingProfile) -> PixelPlane<UInt8> {
        let width = image.width
        let height = image.height
        guard profile.sharpenAmount > 0, width > 2, height > 2 else { return image }
        let lumaPlane = lumaValues(image)
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        memcpy(output.pointer, image.pointer, image.count)
        let amount = profile.sharpenAmount
        let threshold = profile.sharpenThresholdLevels
        let overshoot = profile.sharpenOvershootLevels
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                var sum = 0
                for dy in -1...1 {
                    let row = index + dy * width
                    sum += Int(lumaPlane[row - 1]) + Int(lumaPlane[row]) + Int(lumaPlane[row + 1])
                }
                let detail = Float(lumaPlane[index]) - Float(sum) / 9
                guard abs(detail) > threshold else { continue }
                let delta = min(overshoot, max(-overshoot, amount * detail))
                let q = output.pointer + index * 4
                q[0] = UInt8(min(255, max(0, Float(q[0]) + delta + 0.5)))
                q[1] = UInt8(min(255, max(0, Float(q[1]) + delta + 0.5)))
                q[2] = UInt8(min(255, max(0, Float(q[2]) + delta + 0.5)))
            }
        }
        return output
    }

    // MARK: - Crop

    /// The largest 4:3 (source-aspect) rectangle every aligned frame covers with real pixels.
    static func safeCrop(transforms: [HDRTransformV2], width: Int, height: Int) -> HDRCropV2 {
        var left = 0.0
        var right = 0.0
        var top = 0.0
        var bottom = 0.0
        let w = Double(width)
        let h = Double(height)
        let cx = (w - 1) / 2
        let cy = (h - 1) / 2
        let moving = transforms.filter { $0 != .identity }
        for _ in 0..<200 {
            var grew = false
            for transform in moving {
                let theta = transform.rotationDegrees * .pi / 180
                let scale = 1 + transform.scaleDelta
                let a = scale * cos(theta)
                let b = scale * sin(theta)
                let corners: [(x: Double, y: Double, isLeft: Bool, isTop: Bool)] = [
                    (left, top, true, true),
                    (w - 1 - right, top, false, true),
                    (left, h - 1 - bottom, true, false),
                    (w - 1 - right, h - 1 - bottom, false, false),
                ]
                for corner in corners {
                    let dx = corner.x - cx
                    let dy = corner.y - cy
                    let sx = a * dx - b * dy + cx + transform.translationX
                    let sy = b * dx + a * dy + cy + transform.translationY
                    if sx < 0 || sx > w - 1 {
                        let overshoot = sx < 0 ? -sx : sx - (w - 1)
                        if corner.isLeft { left += max(0.5, overshoot) } else { right += max(0.5, overshoot) }
                        grew = true
                    }
                    if sy < 0 || sy > h - 1 {
                        let overshoot = sy < 0 ? -sy : sy - (h - 1)
                        if corner.isTop { top += max(0.5, overshoot) } else { bottom += max(0.5, overshoot) }
                        grew = true
                    }
                }
            }
            if !grew || left + right > w / 2 || top + bottom > h / 2 { break }
        }

        // Keep the source aspect (4:3): trim the longer side symmetrically, never stretch.
        let aspect = w / h
        let innerWidth = w - left - right
        let innerHeight = h - top - bottom
        if innerWidth / innerHeight > aspect {
            let extra = innerWidth - innerHeight * aspect
            left += extra / 2
            right += extra / 2
        } else {
            let extra = innerHeight - innerWidth / aspect
            top += extra / 2
            bottom += extra / 2
        }
        let l = Int(left.rounded(.up))
        let t = Int(top.rounded(.up))
        var r = Int(right.rounded(.up))
        var cropWidth = width - l - r
        var cropHeight = Int((Double(cropWidth) / aspect).rounded(.down))
        if cropHeight > height - t - Int(bottom.rounded(.up)) {
            cropHeight = height - t - Int(bottom.rounded(.up))
            cropWidth = Int((Double(cropHeight) * aspect).rounded(.down))
            r = width - l - cropWidth
        }
        let b = height - t - cropHeight
        return HDRCropV2(cropLeft: l, cropRight: r, cropTop: t, cropBottom: b, sourceWidth: width, sourceHeight: height)
    }

    struct Cropped {
        var plane: PixelPlane<UInt8>
        var width: Int
        var height: Int
    }

    static func cropped(_ image: PixelPlane<UInt8>, crop: HDRCropV2) -> Cropped {
        let width = crop.width
        let height = crop.height
        guard crop.cropLeft != 0 || crop.cropTop != 0 || width != image.width || height != image.height else {
            return Cropped(plane: image, width: image.width, height: image.height)
        }
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        for y in 0..<height {
            memcpy(
                output.pointer + y * width * 4,
                image.pointer + ((y + crop.cropTop) * image.width + crop.cropLeft) * 4,
                width * 4
            )
        }
        return Cropped(plane: output, width: width, height: height)
    }

    // MARK: - Quality check

    struct ImageStats {
        var meanLuma: Double
        var highlight: Double
        var shadow: Double
        /// Immerkær noise sigma, in 8-bit levels.
        var noise: Double
        /// Mean absolute luminance gradient, in 8-bit levels.
        var sharpness: Double
    }

    static func imageStats(_ image: Cropped) -> ImageStats {
        let width = image.width
        let height = image.height
        let lumaPlane = lumaValues(image.plane)
        var highlight = 0
        var shadow = 0
        var sampled = 0
        var lumaSum = 0.0
        var index = 0
        let count = width * height
        while index < count {
            let p = image.plane.pointer + index * 4
            let value = max(p[0], p[1], p[2])
            if value >= 250 { highlight += 1 }
            if value <= 6 { shadow += 1 }
            lumaSum += Double(lumaPlane[index])
            sampled += 1
            index += 7
        }
        var noiseSum = 0.0
        var gradientSum = 0.0
        var measured = 0
        if width > 2 && height > 2 {
            var y = 1
            while y < height - 1 {
                var x = 1
                while x < width - 1 {
                    let i = y * width + x
                    func l(_ offset: Int) -> Double { Double(lumaPlane[i + offset]) }
                    let laplacian = l(-width - 1) - 2 * l(-width) + l(-width + 1)
                        - 2 * l(-1) + 4 * l(0) - 2 * l(1)
                        + l(width - 1) - 2 * l(width) + l(width + 1)
                    noiseSum += abs(laplacian)
                    gradientSum += abs(l(1) - l(-1)) / 2 + abs(l(width) - l(-width)) / 2
                    measured += 1
                    x += 3
                }
                y += 3
            }
        }
        guard sampled > 0 else { return ImageStats(meanLuma: 0, highlight: 0, shadow: 0, noise: 0, sharpness: 0) }
        return ImageStats(
            meanLuma: lumaSum / Double(sampled) / 255,
            highlight: Double(highlight) / Double(sampled) * 100,
            shadow: Double(shadow) / Double(sampled) * 100,
            noise: measured > 0 ? (Double.pi / 2).squareRoot() / 6 * noiseSum / Double(measured) : 0,
            sharpness: measured > 0 ? gradientSum / Double(measured) : 0
        )
    }

    struct QualityInputs {
        var meanLuma: Double
        var width: Int
        var height: Int
        var sourceAspect: Double
        var processingLongSide: Int
        var highlightClip: Double
        var shadowClip: Double
        var alignmentConfidence: Double
        var crop: HDRCropV2
        var motionCoverage: Double
        var ghostingRisk: HDRGhostingRisk
        var deghostConfidence: Double
        var noise: Double
        var sharpness: Double
        var geometrySafe: Bool
    }

    struct QualityReport {
        var result: HDRQualityResult
        var checks: [HDRQualityCheckV2]
        var warningTags: [String]
        var failureCode: String?
        var failureKind: HDRProcessingFailure.Kind
    }

    static func qualityChecks(_ input: QualityInputs, profile: HDRProcessingProfile) -> QualityReport {
        var checks: [HDRQualityCheckV2] = []
        var tags: [String] = []
        var failureCode: String?
        var failureKind: HDRProcessingFailure.Kind = .technical
        func add(_ name: String, _ result: HDRQualityResult, _ detail: String, tag: String? = nil, code: String? = nil, kind: HDRProcessingFailure.Kind = .technical) {
            checks.append(HDRQualityCheckV2(name: name, result: result, detail: detail))
            if result == .warning, let tag { tags.append(tag) }
            if result == .fail, failureCode == nil {
                failureCode = code
                failureKind = kind
            }
        }

        let exposureOK = input.meanLuma > 0.03 && input.meanLuma < 0.97
        add("exposure", exposureOK ? .pass : .fail, String(format: "mean %.2f", input.meanLuma), code: Code.toneMapFailed)

        let aspect = Double(input.width) / Double(max(1, input.height))
        let aspectOK = abs(aspect - input.sourceAspect) <= 0.01 * input.sourceAspect
        add("aspect", aspectOK ? .pass : .fail, String(format: "%.4f vs %.4f", aspect, input.sourceAspect), code: Code.cropExcessive, kind: .sourceRejected)

        let longSide = max(input.width, input.height)
        let minimum = min(profile.minMasterLongSide, Int(Double(input.processingLongSide) * 0.85))
        add("resolution", longSide >= minimum ? .pass : .warning, "\(input.width) × \(input.height)", tag: Warning.resolution)

        add("highlightClipping", input.highlightClip <= profile.maxHighlightClipPercent ? .pass : .warning,
            String(format: "%.2f%%", input.highlightClip), tag: Warning.highlightClipping)
        add("shadowClipping", input.shadowClip <= profile.maxShadowClipPercent ? .pass : .warning,
            String(format: "%.2f%%", input.shadowClip), tag: Warning.shadowClipping)

        add("alignment", input.alignmentConfidence >= profile.warnAlignmentConfidence ? .pass : .warning,
            String(format: "confidence %.2f", input.alignmentConfidence), tag: Warning.lowAlignmentConfidence)

        let cropMax = max(input.crop.cropPercentX, input.crop.cropPercentY)
        let cropResult: HDRQualityResult = cropMax > profile.maxCropPercent ? .fail : cropMax > profile.targetCropPercent ? .warning : .pass
        add("crop", cropResult, String(format: "X %.1f%% · Y %.1f%%", input.crop.cropPercentX, input.crop.cropPercentY),
            tag: Warning.cropAboveTarget, code: Code.cropExcessive, kind: .sourceRejected)

        let ghosting: HDRQualityResult
        if input.motionCoverage > profile.ghostingExcessivePercent {
            ghosting = .fail
        } else if input.ghostingRisk == .high || input.deghostConfidence < profile.minDeghostConfidence {
            ghosting = .warning
        } else {
            ghosting = .pass
        }
        add("ghosting", ghosting, String(format: "%@ · motion %.2f%% · deghost %.2f", input.ghostingRisk.rawValue, input.motionCoverage, input.deghostConfidence),
            tag: Warning.ghosting, code: Code.ghostingExcessive, kind: .sourceRejected)

        add("noise", input.noise <= profile.maxNoiseEstimate ? .pass : .warning, String(format: "σ %.2f", input.noise), tag: Warning.noise)
        add("sharpness", input.sharpness >= profile.minSharpnessEstimate ? .pass : .warning, String(format: "%.2f", input.sharpness), tag: Warning.sharpness)
        add("geometry", input.geometrySafe ? .pass : .fail, input.geometrySafe ? "within limits" : "unsafe transform merged",
            code: Code.alignmentUnsafe, kind: .sourceRejected)

        let result = checks.map(\.result).max() ?? .pass
        return QualityReport(result: result, checks: checks, warningTags: tags, failureCode: failureCode, failureKind: failureKind)
    }

    // MARK: - Memory

    /// Full source resolution when memory allows, otherwise the first fallback that fits.
    static func chooseWorkingMaxPixel(sourceLongSide: Int, aspect: Double, profile: HDRProcessingProfile) throws -> Int {
        let preferred = profile.preferredMaxPixel > 0 ? min(profile.preferredMaxPixel, sourceLongSide) : sourceLongSide
        let candidates = [preferred] + profile.fallbackMaxPixels.filter { $0 < preferred }
        let available = Double(os_proc_available_memory())
        // 0 = not reported (simulator): trust the preferred size.
        guard available > 0 else { return preferred }
        let shortRatio = aspect >= 1 ? 1 / aspect : aspect
        for candidate in candidates {
            let pixels = Double(candidate) * Double(candidate) * shortRatio
            if pixels * profile.bytesPerWorkingPixel * profile.memoryHeadroom < available {
                return candidate
            }
        }
        throw failure(Code.memoryPressure, .technical, String(format: "available %.0f MB", available / 1_048_576))
    }

    // MARK: - Pixels

    struct RGBXImage {
        var plane: PixelPlane<UInt8>
        var width: Int
        var height: Int
    }

    /// Sensor-orientation decode (no EXIF transform), so every exposure shares one geometry.
    static func decodeRGBX(url: URL, maxPixel: Int) throws -> RGBXImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw failure(Code.inputInvalid, .technical, url.lastPathComponent)
        }
        let width = image.width
        let height = image.height
        let plane = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: plane.pointer,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            throw failure(Code.inputInvalid, .technical, "context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBXImage(plane: plane, width: width, height: height)
    }

    static func lumaValues(_ image: PixelPlane<UInt8>) -> [UInt8] {
        let count = image.width * image.height
        var output = [UInt8](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { destination in
            for index in 0..<count {
                let p = image.pointer + index * 4
                destination[index] = UInt8((54 * Int(p[0]) + 183 * Int(p[1]) + 19 * Int(p[2])) >> 8)
            }
        }
        return output
    }

    static func luma(_ image: RGBXImage) -> GrayImage {
        GrayImage(width: image.width, height: image.height, pixels: lumaValues(image.plane))
    }

    static func median(_ pixels: [UInt8]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let half = pixels.count / 2
        var cumulative = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half { return value }
        }
        return 128
    }

    static func makeImage(_ plane: PixelPlane<UInt8>, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: plane.pointer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
    }

    static func jpegData(_ image: CGImage, orientation: Int, quality: Double) -> Data? {
        encode(image, type: UTType.jpeg, orientation: orientation, quality: quality)
    }

    private static func grayPNG(_ pixels: [UInt8], width: Int, height: Int, orientation: Int) -> Data? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw -> Data? in
            guard let image = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage() else { return nil }
            return encode(image, type: UTType.png, orientation: orientation, quality: 1)
        }
    }

    private static func encode(_ image: CGImage, type: UTType, orientation: Int, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: pipelineVersion],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func resized(_ master: Data, maxPixel: Int, orientation: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(master as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return jpegData(image, orientation: orientation, quality: quality)
    }

    static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private static func isDecodable(_ data: Data) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
}

// MARK: - Storage

/// `hdr_master_v2.json` — beside, never instead of, V1's `hdr_master.json`.
nonisolated enum HDRMasterV2Store {
    static func write(_ record: HDRMasterV2Record) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let url = CaptureBundleStore.url(clientCaptureID: record.clientCaptureID, fileName: HDRPipelineV2.recordFileName),
              let data = try? encoder.encode(record)
        else {
            throw HDRProcessingFailure(code: HDRPipelineV2.Code.outputWriteFailed, kind: .technical, detail: "record")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw HDRProcessingFailure(code: HDRPipelineV2.Code.outputWriteFailed, kind: .technical, detail: "record write")
        }
    }

    /// The record of a V2 master whose file still exists with the recorded size, else `nil`.
    static func read(clientCaptureID: UUID) -> HDRMasterV2Record? {
        guard let url = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: HDRPipelineV2.recordFileName),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(HDRMasterV2Record.self, from: data),
              let master = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: record.fileName),
              let attributes = try? FileManager.default.attributesOfItem(atPath: master.path),
              (attributes[.size] as? NSNumber)?.intValue == record.fileSize
        else { return nil }
        return record
    }

    static func path(_ record: HDRMasterV2Record) -> String {
        CaptureBundleStore.url(clientCaptureID: record.clientCaptureID, fileName: record.fileName)?.path ?? record.fileName
    }
}

private extension Array where Element == Double {
    nonisolated var average: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
