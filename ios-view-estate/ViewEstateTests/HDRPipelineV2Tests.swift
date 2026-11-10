//
//  HDRPipelineV2Tests.swift
//  ViewEstateTests
//
//  VE-HDR 2.0. Synthetic fixtures prove algorithm behaviour (alignment, exclusion, crop,
//  motion, clipping recovery, output verification) — never photographic quality, which is
//  validated physically on the iPhone.
//

import Foundation
import ImageIO
import Testing
import UIKit
@testable import ViewEstate

@MainActor
@Suite(.serialized)
struct HDRPipelineV2Tests {

    // MARK: - Versioning & output

    @Test func versioningAndVerifiedOutput() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id)
        let sourceChecksums = frames.map(\.checksum)
        let captureID = UUID()

        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: captureID) { _ in }.get()

        #expect(record.pipelineVersion == "VE-HDR 2.0")
        #expect(record.profileVersion == "REAL_ESTATE_STANDARD_V2")
        #expect(record.captureID == captureID)
        #expect(record.fileName == "hdr_master_v2.jpg")
        #expect(record.previewFileName == "hdr_preview_v2.jpg")

        // Real file: exists, size, checksum, decodable dimensions.
        let url = try #require(CaptureBundleStore.url(clientCaptureID: id, fileName: record.fileName))
        let data = try Data(contentsOf: url)
        #expect(data.count == record.fileSize && record.fileSize > 0)
        #expect(CaptureBundleStore.checksum(data) == record.checksum)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == record.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == record.height)
        #expect(CaptureBundleStore.url(clientCaptureID: id, fileName: record.previewFileName) != nil)
        #expect(HDRMasterV2Store.read(clientCaptureID: id)?.checksum == record.checksum)

        // FULL_9 prefers every frame; EV 0 is the reference.
        #expect(record.inputFrameIDs.count + record.excludedFrameIDs.count == 9)
        #expect(record.inputFrameIDs.count >= 7)
        let reference = try #require(frames.first { $0.requestedEV == 0 })
        #expect(record.referenceFrameID == reference.id)

        // Sources are never modified.
        for (frame, checksum) in zip(frames, sourceChecksums) {
            let bytes = try #require(CaptureBundleStore.loadData(frame))
            #expect(CaptureBundleStore.checksum(bytes) == checksum)
        }
    }

    // MARK: - EV 0

    @Test func missingEV0FailsTheJob() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id).filter { $0.requestedEV != 0 }
        let result = HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }
        guard case .failure(let failure) = result else {
            Issue.record("A bracket without EV 0 must never produce a V2 master")
            return
        }
        #expect(failure.code == HDRPipelineV2.Code.inputInvalid)
        #expect(HDRMasterV2Store.read(clientCaptureID: id) == nil)
    }

    // MARK: - Alignment

    @Test func alignmentMetadataIsRecordedPerFrame() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id)
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        #expect(record.alignments.count == record.inputFrameIDs.count)
        let reference = try #require(record.alignments.first { $0.alignmentStatus == .reference })
        #expect(reference.frameID == record.referenceFrameID)
        #expect(reference.transform == .identity)
        #expect(reference.alignmentConfidence == 1)
        for alignment in record.alignments where alignment.alignmentStatus == .aligned {
            #expect(alignment.alignmentConfidence >= 0 && alignment.alignmentConfidence <= 1)
            // A static tripod scene needs (almost) no correction.
            #expect(abs(alignment.translationX) < 1.01 && abs(alignment.translationY) < 1.01)
            #expect(abs(alignment.rotationDegrees) < 0.3)
        }
    }

    @Test func knownTranslationIsRecoveredDirectlyAgainstEV0() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id) { ev in
            ev == 0 ? .none : Motion(shiftX: 6, shiftY: -4)
        }
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        for alignment in record.alignments where abs(alignment.relativeEV) <= 2.1 && alignment.alignmentStatus == .aligned {
            #expect(abs(abs(alignment.translationX) - 6) < 1.0, "EV \(alignment.evLabel): \(alignment.translationX)")
            #expect(abs(abs(alignment.translationY) - 4) < 1.0, "EV \(alignment.evLabel): \(alignment.translationY)")
        }
        // Crop is recorded, small, and keeps 4:3.
        #expect(record.crop.cropPercentX > 0)
        #expect(record.cropPercentX <= 5 && record.cropPercentY <= 5)
        let aspect = Double(max(record.width, record.height)) / Double(min(record.width, record.height))
        #expect(abs(aspect - 4.0 / 3.0) < 0.015)
        #expect(record.crop.cropLeft + record.crop.cropRight + record.crop.width == record.crop.sourceWidth)
    }

    @Test func smallRotationIsCorrected() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id) { ev in
            ev == 0 ? .none : Motion(rotation: 0.8)
        }
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        let measured = record.alignments.filter { abs($0.relativeEV) <= 2.1 && $0.alignmentStatus == .aligned }
        #expect(!measured.isEmpty)
        for alignment in measured {
            #expect(abs(abs(alignment.rotationDegrees) - 0.8) < 0.2, "EV \(alignment.evLabel): \(alignment.rotationDegrees)°")
        }
        #expect(record.maxRotationCorrection > 0.5)
        #expect(record.qualityChecks.first { $0.name == "geometry" }?.result == .pass)
    }

    @Test func unsafeRotationExcludesThatFrameOnly() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id) { ev in
            ev == 1 ? Motion(rotation: 2.0) : .none
        }
        let unsafeFrame = try #require(frames.first { $0.requestedEV == 1 })
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        #expect(record.excludedFrameIDs.contains(unsafeFrame.id))
        #expect(!record.inputFrameIDs.contains(unsafeFrame.id))
        let exclusion = try #require(record.exclusions.first { $0.excludedFrameID == unsafeFrame.id })
        #expect(exclusion.exclusionReason.contains("rotation"))
        #expect(record.qualityResult != .fail)
    }

    @Test func safetyLimitsRejectUnsafeTransforms() {
        let profile = HDRProcessingProfile.realEstateStandardV2
        let safe = HDRTransformV2(translationX: 40, translationY: -30, rotationDegrees: 1.0, scaleDelta: 0.01)
        #expect(HDRPipelineV2.safetyViolation(safe, width: 4032, height: 3024, profile: profile) == nil)

        let rotation = HDRTransformV2(translationX: 0, translationY: 0, rotationDegrees: 2.0, scaleDelta: 0)
        #expect(HDRPipelineV2.safetyViolation(rotation, width: 4032, height: 3024, profile: profile)?.contains("rotation") == true)

        let translation = HDRTransformV2(translationX: 200, translationY: 0, rotationDegrees: 0, scaleDelta: 0)
        #expect(HDRPipelineV2.safetyViolation(translation, width: 4032, height: 3024, profile: profile)?.contains("translation") == true)

        let scale = HDRTransformV2(translationX: 0, translationY: 0, rotationDegrees: 0, scaleDelta: 0.03)
        #expect(HDRPipelineV2.safetyViolation(scale, width: 4032, height: 3024, profile: profile)?.contains("scale") == true)
    }

    @Test func safeCropKeepsAspectAndNeverStretches() {
        let transforms = [
            HDRTransformV2.identity,
            HDRTransformV2(translationX: 12, translationY: -8, rotationDegrees: 0, scaleDelta: 0),
            HDRTransformV2(translationX: 0, translationY: 0, rotationDegrees: 0.6, scaleDelta: 0),
        ]
        let crop = HDRPipelineV2.safeCrop(transforms: transforms, width: 4000, height: 3000)
        #expect(crop.width > 0 && crop.height > 0)
        #expect(crop.width <= 4000 && crop.height <= 3000)
        #expect(abs(Double(crop.width) / Double(crop.height) - 4.0 / 3.0) < 0.002)
        #expect(crop.cropLeft > 0 && crop.cropRight > 0 && crop.cropTop > 0 && crop.cropBottom > 0)
        #expect(crop.cropPercentX < 5 && crop.cropPercentY < 5)

        let none = HDRPipelineV2.safeCrop(transforms: [.identity], width: 4000, height: 3000)
        #expect(none.cropPercentX == 0 && none.cropPercentY == 0)
    }

    // MARK: - Motion & deghost

    @Test func movingObjectIsDetectedAndDeghosted() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id) { ev in
            switch ev {
            case -1: Motion(object: CGRect(x: 40, y: 40, width: 50, height: 60))
            case 1: Motion(object: CGRect(x: 130, y: 40, width: 50, height: 60))
            default: .none
            }
        }
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        #expect(record.motionDetected)
        #expect(record.motionCoverage > 0.5)
        #expect(record.motionCoverage < 45)
        #expect(record.ghostingRisk != .none)
        #expect(record.deghostApplied)
        #expect(record.deghostConfidence > 0.5)
        #expect(record.labMotionMaskFileName != nil)
    }

    @Test func staticSceneHasNoMotion() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id)
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()
        #expect(!record.deghostApplied)
        #expect(record.motionCoverage < 0.5)
        #expect(!record.warnings.contains(HDRPipelineV2.Warning.ghosting))
    }

    // MARK: - Clipping & quality metrics

    @Test func highlightAndShadowClippingAreRecoveredAndMeasured() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id)
        let record = try HDRPipelineV2.process(manifest: Self.manifest(frames, id), captureID: UUID()) { _ in }.get()

        // EV 0 blows the window; the master recovers it.
        #expect(record.ev0HighlightClipping > 5)
        #expect(record.highlightClipping < record.ev0HighlightClipping * 0.6)
        #expect(record.shadowClipping <= record.ev0ShadowClipping + 1)

        // Every QA check ran and recorded a result.
        let names = Set(record.qualityChecks.map(\.name))
        for name in ["exposure", "aspect", "resolution", "highlightClipping", "shadowClipping", "alignment", "crop", "ghosting", "noise", "sharpness", "geometry"] {
            #expect(names.contains(name), "missing QA check \(name)")
        }
        #expect(record.noiseEstimate >= 0)
        #expect(record.sharpnessEstimate > 0)
        #expect(record.qualityResult != .fail)
        #expect(record.processingDuration > 0)
        #expect(record.processingWidth > 0 && record.processingHeight > 0)
    }

    @Test func qualityCheckFailsOnBlackImage() {
        let profile = HDRProcessingProfile.realEstateStandardV2
        let report = HDRPipelineV2.qualityChecks(HDRPipelineV2.QualityInputs(
            meanLuma: 0.0, width: 4000, height: 3000, sourceAspect: 4.0 / 3.0, processingLongSide: 4000,
            highlightClip: 0, shadowClip: 100, alignmentConfidence: 1,
            crop: HDRCropV2(cropLeft: 0, cropRight: 0, cropTop: 0, cropBottom: 0, sourceWidth: 4000, sourceHeight: 3000),
            motionCoverage: 0, ghostingRisk: .none, deghostConfidence: 1, noise: 1, sharpness: 5, geometrySafe: true
        ), profile: profile)
        #expect(report.result == .fail)
        #expect(report.failureCode == HDRPipelineV2.Code.toneMapFailed)
    }

    // MARK: - V1 coexistence

    @Test func v2NeverOverwritesV1() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(clientCaptureID: id)
        let manifest = Self.manifest(frames, id)

        let v1 = try HDRProcessingService.process(manifest: manifest, captureID: UUID()) { _ in }.get()
        let v1URL = try #require(CaptureBundleStore.url(clientCaptureID: id, fileName: v1.fileName))
        let v1Checksum = CaptureBundleStore.checksum(try Data(contentsOf: v1URL))

        let v2 = try HDRPipelineV2.process(manifest: manifest, captureID: UUID()) { _ in }.get()

        #expect(v2.fileName != v1.fileName)
        #expect(v2.previewFileName != v1.previewFileName)
        #expect(CaptureBundleStore.checksum(try Data(contentsOf: v1URL)) == v1Checksum)
        #expect(HDRMasterStore.read(clientCaptureID: id)?.checksum == v1.checksum)
        #expect(HDRMasterV2Store.read(clientCaptureID: id)?.checksum == v2.checksum)
        #expect(v1.pipelineVersion == HDRProcessingService.pipelineVersion)
    }

    // MARK: - App flow

    @Test func appRunsV2ByDefaultKeepsLineageAndCostsNothing() async throws {
        let state = AppState()
        state.realHDREnabled = true
        #expect(state.hdrPipeline == .v2)
        let (capture, live, manifest) = try await Self.captureAndWait(state)
        defer { CaptureBundleStore.delete(clientCaptureID: manifest.clientCaptureID) }

        #expect(live.status == .ready)
        #expect(live.hdrState == .generated)
        let v2 = try #require(live.hdrMasterV2)
        #expect(live.hdrMaster == nil)
        #expect(live.activeMaster?.assetID == v2.assetID)
        #expect(live.displayFile?.fileName == "hdr_master_v2.jpg")
        #expect(live.assets.first?.type == .original)
        let asset = try #require(live.assets.first { $0.id == v2.assetID })
        #expect(asset.versionNumber == 2)
        #expect(asset.parentAssetID == live.originalAsset?.id)
        #expect(state.lastHDRV2Result?.checksum == v2.checksum)
        #expect(state.hdrJobs[capture.id]?.stage == .done)

        #expect(state.wallet.total == Self.balance)
        #expect(state.transactions.count == Self.transactionCount)
    }

    @Test func bothPipelinesKeepV1AndShowV2() async throws {
        let state = AppState()
        state.realHDREnabled = true
        state.hdrPipeline = .both
        let (_, live, manifest) = try await Self.captureAndWait(state)
        defer { CaptureBundleStore.delete(clientCaptureID: manifest.clientCaptureID) }

        #expect(live.status == .ready)
        let v1 = try #require(live.hdrMaster)
        let v2 = try #require(live.hdrMasterV2)
        #expect(v1.fileName != v2.fileName)
        #expect(live.activeMaster?.assetID == v2.assetID)
        #expect(live.assets.filter { $0.type == .hdrMaster }.count == 2)
        #expect(CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: v1.fileName) != nil)

        state.setActiveHDRVersion(.v1, for: live.id)
        let switched = try #require(state.captures.first { $0.id == live.id })
        #expect(switched.activeMaster?.assetID == v1.assetID)
        #expect(state.wallet.total == Self.balance)
    }

    // MARK: - Fixtures

    private static let width = 400
    private static let height = 300
    nonisolated(unsafe) private static var balance = 0
    nonisolated(unsafe) private static var transactionCount = 0

    struct Motion {
        var shiftX: Double = 0
        var shiftY: Double = 0
        var rotation: Double = 0
        /// A bright object present only in this exposure (scene coordinates).
        var object: CGRect?

        static let none = Motion()
    }

    private static func captureAndWait(_ state: AppState) async throws -> (CaptureItem, CaptureItem, CaptureManifest) {
        let property = try #require(state.properties.first)
        balance = state.wallet.total
        transactionCount = state.transactions.count
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let frames = try writeScene(clientCaptureID: attempt.id)
        var manifest = manifest(frames, attempt.id)
        manifest.propertyID = property.id
        try CaptureBundleStore.writeManifest(manifest)
        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living,
            frameCount: manifest.actualFrameCount,
            localFile: manifest.referenceFrame?.localPhotoFile,
            manifest: manifest
        )
        state.endCaptureSequence()
        var live = capture
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            live = try #require(state.captures.first { $0.id == capture.id })
            if live.status != .preparing { break }
        }
        return (capture, live, manifest)
    }

    /// Deterministic cell reflectance 0.15…0.85.
    private static func reflectance(_ cx: Int, _ cy: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: cx &* 73_856_093 ^ cy &* 19_349_663)
        h ^= h >> 13
        h = h &* 1_274_126_177
        h ^= h >> 16
        return 0.15 + 0.7 * Double(h % 1000) / 999
    }

    /// Linear scene radiance: textured room (16 px cells), a bright window with mullions that
    /// EV 0 clips, and a deep shadow corner EV 0 crushes.
    private static func radiance(_ u: Double, _ v: Double, object: CGRect?) -> Double {
        if let object, object.contains(CGPoint(x: u, y: v)) { return 0.25 }
        let cx = Int((u / 16).rounded(.down))
        let cy = Int((v / 16).rounded(.down))
        let r = reflectance(cx, cy)
        if u >= 250, u < 370, v >= 30, v < 150 {
            let mullion = Int(u - 250) % 40 < 3 || Int(v - 30) % 40 < 3
            return mullion ? 0.05 : 3.0 * (0.75 + 0.25 * r)
        }
        var value = 0.12 * r
        if u < 120, v > 190 { value *= 0.01 }
        return value
    }

    private static func exposure(ev: Double, motion: Motion) -> Data {
        let w = width, h = height
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let theta = motion.rotation * .pi / 180
        let cosT = cos(theta), sinT = sin(theta)
        let gain = pow(2, ev)
        let offsets: [(Double, Double)] = [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)]
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for (ox, oy) in offsets {
                    let dx = Double(x) + ox - cx
                    let dy = Double(y) + oy - cy
                    let u = cosT * dx - sinT * dy + cx - motion.shiftX
                    let v = sinT * dx + cosT * dy + cy - motion.shiftY
                    sum += min(1, radiance(u, v, object: motion.object) * gain)
                }
                let encoded = UInt8(max(0, min(255, (pow(sum / 4, 1 / 2.2) * 255).rounded())))
                let i = (y * w + x) * 4
                pixels[i] = encoded
                pixels[i + 1] = encoded
                pixels[i + 2] = encoded
            }
        }
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
        guard let image else { return Data() }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.95) ?? Data()
    }

    private static func writeScene(
        clientCaptureID: UUID,
        motion: (Double) -> Motion = { _ in .none }
    ) throws -> [CaptureFrame] {
        try CaptureProfile.full9.exposureValues.enumerated().map { index, ev in
            var frame = try CaptureBundleStore.writeFrame(
                photoData: exposure(ev: ev, motion: motion(ev)),
                clientCaptureID: clientCaptureID,
                sequenceIndex: index,
                requestedEV: ev,
                orientation: .portrait,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
            frame.actualExposureBias = ev
            frame.iso = 100
            frame.exposureDurationSeconds = 0.01 * pow(2, ev)
            return frame
        }
    }

    private static func manifest(_ frames: [CaptureFrame], _ clientCaptureID: UUID) -> CaptureManifest {
        CaptureManifest(
            captureID: nil,
            clientCaptureID: clientCaptureID,
            organizationID: "Test Workspace",
            propertyID: UUID(),
            roomID: RoomType.living.rawValue,
            device: "iPhone14,7",
            iOSVersion: "iOS 26.0",
            appVersion: "1.0.0 (1)",
            cameraID: "test-camera",
            lensType: "Rear Wide",
            captureProfile: .full9,
            expectedFrameCount: CaptureProfile.full9.expectedFrameCount,
            actualFrameCount: frames.count,
            segmentCount: 2,
            orientation: .portrait,
            focusLockSucceeded: .succeeded,
            whiteBalanceLockSucceeded: .succeeded,
            state: .localReady,
            startedAt: .now,
            completedAt: nil,
            frames: frames,
            requestedExposureValues: CaptureProfile.full9.exposureValues
        )
    }
}
