//
//  ViewEstateTests.swift
//  ViewEstateTests
//

import Foundation
import Testing
import UIKit
@testable import ViewEstate

/// Capture flow domain tests. They lock the approved rules: one shutter action is one
/// capture, idempotency is keyed on the capture attempt (never on a time window), and
/// standard photography never touches the credit wallet.
@MainActor
struct CaptureFlowTests {

    private func makeState() -> AppState {
        let state = AppState()
        state.preparationSeconds = 0.05
        return state
    }

    // 1. Two duplicate events from ONE shutter action create only one capture.
    @Test func duplicateEventsFromSameAttemptCreateOneCapture() async throws {
        let state = makeState()
        let property = try #require(state.properties.first)
        let before = state.captures.count

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let first = state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
        let replay = state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        #expect(first.id == replay.id)
        #expect(first.clientCaptureID == attempt.id)
        #expect(state.captures.count == before + 1)
    }

    // 2. Two separate shutter actions in the same room create two different captures,
    //    even when they happen within the same second.
    @Test func separateAttemptsInSameRoomCreateTwoCaptures() async throws {
        let state = makeState()
        let property = try #require(state.properties.first)
        let before = state.captures.count

        let firstAttempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let first = state.registerCapture(attempt: firstAttempt, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        let secondAttempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let second = state.registerCapture(attempt: secondAttempt, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        #expect(firstAttempt.id != secondAttempt.id)
        #expect(first.id != second.id)
        #expect(state.captures.count == before + 2)
        #expect(second.createdAt.timeIntervalSince(first.createdAt) < 1)
    }

    // While CAPTURING, no second attempt may start.
    @Test func shutterIsLockedWhileCapturing() async throws {
        let state = makeState()
        let property = try #require(state.properties.first)

        let attempt = state.beginCaptureAttempt(property: property, room: .kitchen)
        #expect(attempt != nil)
        #expect(state.captureSessionState == .capturing)
        #expect(state.beginCaptureAttempt(property: property, room: .kitchen) == nil)

        state.endCaptureSequence()
        #expect(state.captureSessionState == .idle)
    }

    // 3. Standard photography never changes the credit wallet.
    @Test func captureDoesNotChangeCreditWallet() async throws {
        let state = makeState()
        let property = try #require(state.properties.first)
        let balance = state.wallet.total
        let transactions = state.transactions.count

        for room in [RoomType.living, .kitchen, .bedroom, .bathroom] {
            let attempt = try #require(state.beginCaptureAttempt(property: property, room: room))
            state.registerCapture(attempt: attempt, property: property, room: room, frameCount: 9)
            state.endCaptureSequence()
        }

        #expect(state.wallet.total == balance)
        #expect(state.transactions.count == transactions)
    }

    // A simulated capture still moves A preparar → Pronta, but never claims an HDR master:
    // no real HDR file exists for it.
    @Test func mockPreparationReachesReadyWithoutClaimingAnHDRMaster() async throws {
        let state = makeState()
        let property = try #require(state.properties.first)

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let capture = state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        #expect(capture.status == .preparing)
        let original = try #require(capture.originalAsset)

        try await Task.sleep(for: .seconds(1.2))
        let prepared = try #require(state.captures.first { $0.id == capture.id })

        #expect(prepared.status == .ready)
        #expect(prepared.originalAsset?.id == original.id)
        #expect(!prepared.assets.contains { $0.type == .hdrMaster })
        #expect(prepared.hdrMaster == nil)
        #expect(prepared.hdrState == .mock)
        #expect(prepared.hdrSource == .mock)
        #expect(prepared.assets.filter { $0.type == .original }.count == 1)
    }

    // A capture still preparing never blocks photographing another room.
    @Test func preparingCaptureDoesNotBlockNextCapture() async throws {
        let state = makeState()
        state.preparationSeconds = 5
        let property = try #require(state.properties.first)

        let first = try #require(state.beginCaptureAttempt(property: property, room: .living))
        state.registerCapture(attempt: first, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        let second = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        let kitchen = state.registerCapture(attempt: second, property: property, room: .kitchen, frameCount: 9)
        state.endCaptureSequence()

        #expect(kitchen.status == .preparing)
        #expect(state.preparingCount >= 2)
    }

    // 4. Offline capture stays available and is marked as pending sync.
    @Test func offlineCaptureRemainsAvailable() async throws {
        let state = makeState()
        state.setOnline(false)
        let property = try #require(state.properties.first)

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .exterior))
        let capture = state.registerCapture(attempt: attempt, property: property, room: .exterior, frameCount: 9)
        state.endCaptureSequence()

        #expect(capture.isPendingSync)
        #expect(capture.status == .preparing)
        #expect(state.syncState == .pending)

        state.setOnline(true)
        try await Task.sleep(for: .seconds(1.2))
        let synced = try #require(state.captures.first { $0.id == capture.id })
        #expect(!synced.isPendingSync)
        #expect(synced.status == .ready)
    }

    // 5. Gallery states: every simulated outcome maps to its user-facing status.
    @Test func galleryStatesRemainIntact() async throws {
        let expectations: [(CaptureResultMode, PreparationStatus)] = [
            (.success, .ready),
            (.needsRecapture, .needsRecapture),
            (.error, .error),
        ]

        for (mode, expected) in expectations {
            let state = makeState()
            state.captureResultMode = mode
            let property = try #require(state.properties.first)

            let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
            let capture = state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
            state.endCaptureSequence()

            try await Task.sleep(for: .seconds(1.2))
            let finished = try #require(state.captures.first { $0.id == capture.id })
            #expect(finished.status == expected)
            // The original survives every outcome.
            #expect(finished.originalAsset != nil)
        }
    }

    // Retrying a failed preparation reuses the immutable original.
    @Test func retryKeepsOriginalImmutable() async throws {
        let state = makeState()
        state.captureResultMode = .error
        let property = try #require(state.properties.first)

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let capture = state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        try await Task.sleep(for: .seconds(1.2))
        let failed = try #require(state.captures.first { $0.id == capture.id })
        #expect(failed.status == .error)
        let originalID = try #require(failed.originalAsset?.id)

        state.captureResultMode = .success
        state.retryPreparation(failed)
        try await Task.sleep(for: .seconds(1.2))

        let recovered = try #require(state.captures.first { $0.id == capture.id })
        #expect(recovered.status == .ready)
        #expect(recovered.originalAsset?.id == originalID)
    }
}

/// Native camera spike: the development test property, local storage of one real original and
/// the orientation contract. No AVFoundation session is started here — hardware behaviour is
/// validated on a physical iPhone.
@MainActor
struct NativeCaptureTests {

    // The reference property exists, is development-only, and its SketchUp source is immutable.
    @Test func developmentPropertyRegistersImmutableSketchUpSource() throws {
        let state = AppState()
        let property = try #require(state.properties.first { $0.title == "Residência Sergio" })

        #expect(property.type == .house)
        #expect(property.lifecycle == .developmentTest)
        #expect(property.isDevelopmentProperty)

        let asset = try #require(property.sourceAsset)
        #expect(asset.fileName == "sergio.skp")
        #expect(asset.format == .sketchupModel)
        #expect(asset.isImmutable)
        // A 3D source is a reference asset: it can never stand in for photographic input.
        #expect(!asset.canFeedCamera)
        #expect(!asset.format.isPhotographic)
    }

    // Future USDZ / GLB derivatives are prepared for, but nothing is converted yet.
    @Test func sourceAssetDerivativesArePreparedButNotGenerated() throws {
        let property = DevFixtures.sergioResidence()
        let asset = try #require(property.sourceAsset)

        #expect(asset.availableDerivatives.isEmpty)
        for format in SourceAssetFormat.plannedConversionTargets {
            let derivative = try #require(asset.derivative(format))
            #expect(derivative.state == .notGenerated)
            #expect(derivative.parentAssetID == asset.id)
            #expect(derivative.fileName == nil)
        }
    }

    // Rotation angles map to device orientation in both directions.
    @Test func captureOrientationMapsRotationAngles() {
        let expectations: [(CGFloat, CaptureOrientation)] = [
            (0, .landscapeRight),
            (90, .portrait),
            (180, .landscapeLeft),
            (270, .portraitUpsideDown),
        ]
        for (angle, orientation) in expectations {
            #expect(CaptureOrientation(videoRotationAngle: angle) == orientation)
            #expect(orientation.videoRotationAngle == angle)
        }
    }

    // A real photograph is written into the app container and the capture keeps the file,
    // the property and the room together — with a local record that needs no connectivity.
    @Test func nativeCaptureStoresOriginalLocallyWithPropertyAndRoom() throws {
        let state = AppState()
        state.preparationSeconds = 0.05
        let property = try #require(state.properties.first { $0.isDevelopmentProperty })

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        let file = try CaptureFileStore.saveOriginal(
            photoData: Self.sampleJPEG(width: 400, height: 300),
            clientCaptureID: attempt.id,
            orientation: .portrait
        )
        let capture = state.registerCapture(
            attempt: attempt,
            property: property,
            room: .kitchen,
            frameCount: 1,
            localFile: file
        )
        state.endCaptureSequence()

        #expect(capture.hasLocalOriginal)
        #expect(capture.frameCount == 1)
        #expect(file.pixelWidth == 400)
        #expect(file.pixelHeight == 300)
        #expect(file.byteCount > 0)

        let path = CaptureFileStore.path(for: file)
        #expect(FileManager.default.fileExists(atPath: path))

        let record = try #require(CaptureFileStore.readRecord(clientCaptureID: attempt.id))
        #expect(record.captureID == capture.id)
        #expect(record.clientCaptureID == attempt.id)
        #expect(record.propertyID == property.id)
        #expect(record.roomID == RoomType.kitchen.rawValue)
        #expect(record.fileName == file.fileName)
        #expect(record.orientation == .portrait)

        // The confirmation the user sees stays the approved one.
        #expect(capture.status == .preparing)

        try? FileManager.default.removeItem(atPath: path)
    }

    // A replayed completion of the same shutter action still resolves to one capture and one file.
    @Test func replayedNativeCompletionKeepsOneCaptureAndOneFile() throws {
        let state = AppState()
        state.preparationSeconds = 0.05
        let property = try #require(state.properties.first)
        let before = state.captures.count

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let data = Self.sampleJPEG(width: 320, height: 240)
        let first = try CaptureFileStore.saveOriginal(
            photoData: data,
            clientCaptureID: attempt.id,
            orientation: .portrait
        )
        let replay = try CaptureFileStore.saveOriginal(
            photoData: data,
            clientCaptureID: attempt.id,
            orientation: .portrait
        )
        #expect(first.fileName == replay.fileName)

        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living, frameCount: 1, localFile: first
        )
        let again = state.registerCapture(
            attempt: attempt, property: property, room: .living, frameCount: 1, localFile: replay
        )
        state.endCaptureSequence()

        #expect(capture.id == again.id)
        #expect(state.captures.count == before + 1)

        try? FileManager.default.removeItem(atPath: CaptureFileStore.path(for: first))
    }

    // The camera mode is switchable and the stage read-out follows READY → CAPTURING → LOCAL_READY.
    @Test func captureStageReportsLocalReadyAfterNativeCapture() throws {
        let state = AppState()
        state.preparationSeconds = 0.05
        state.cameraMode = .native
        #expect(state.captureStageLabel == "READY")

        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        #expect(state.captureStageLabel == "CAPTURING")

        let file = try CaptureFileStore.saveOriginal(
            photoData: Self.sampleJPEG(width: 200, height: 150),
            clientCaptureID: attempt.id,
            orientation: .landscapeLeft
        )
        state.registerCapture(
            attempt: attempt, property: property, room: .living, frameCount: 1, localFile: file
        )
        state.endCaptureSequence()

        #expect(state.captureStageLabel == "LOCAL_READY")
        #expect(state.cameraDiagnostics.lastFile?.fileName == file.fileName)

        try? FileManager.default.removeItem(atPath: CaptureFileStore.path(for: file))
    }

    // Normalised error codes never leak an AVFoundation message.
    @Test func cameraErrorsAreNormalised() {
        #expect(CameraError.permissionDenied.code == "CAMERA_PERMISSION_DENIED")
        #expect(CameraError.initializationFailed.code == "CAMERA_INITIALIZATION_FAILED")
        #expect(CameraError.captureFailed.code == "PHOTO_CAPTURE_FAILED")
        #expect(CameraError.localSaveFailed.code == "LOCAL_SAVE_FAILED")

        let state = AppState()
        for error in [
            CameraError.permissionDenied, .initializationFailed, .captureFailed, .localSaveFailed,
        ] {
            let message = state.t(error.localizationKey)
            #expect(message != error.localizationKey)
            #expect(!message.contains("AV"))
        }
    }

    private static func sampleJPEG(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        // Pixel-exact: the default renderer format uses the screen scale (3× on most simulators).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// Locale coverage: both markets resolve their own terminology from the same components.
@MainActor
struct LocalizationTests {

    @Test func portugalAndBrazilUseTheirOwnTerminology() {
        let state = AppState()

        state.selectRegion(.pt)
        #expect(state.roomName(.bathroom) == "Casa de banho")
        #expect(state.t("status.preparing") == "A preparar")
        #expect(state.t("capture.done.continue") == "Continuar a fotografar")
        #expect(state.t("capture.done.nextRoom") == "Próxima divisão")

        state.selectRegion(.br)
        #expect(state.roomName(.bathroom) == "Banheiro")
        #expect(state.t("status.preparing") == "Preparando")
        #expect(state.t("capture.done.continue") == "Continuar fotografando")
        #expect(state.t("capture.done.nextRoom") == "Próximo cômodo")

        state.selectRegion(.pt)
    }

    // The camera permission copy follows each market's own word for the camera.
    @Test func cameraPermissionCopyIsLocalisedPerMarket() {
        let state = AppState()

        state.selectRegion(.pt)
        #expect(state.t("camera.permission.title").contains("câmara"))
        #expect(state.t("camera.permission.body").contains("câmara"))
        #expect(state.t("camera.permission.cta") == "Abrir Definições")

        state.selectRegion(.br)
        #expect(state.t("camera.permission.title").contains("câmera"))
        #expect(state.t("camera.permission.body").contains("câmera"))
        #expect(state.t("camera.permission.cta") == "Abrir Ajustes")

        state.selectRegion(.pt)
    }

    @Test func everyKeyExistsInBothDictionaries() {
        let missingInBR = Strings.ptPT.keys.filter { Strings.ptBR[$0] == nil }
        let missingInPT = Strings.ptBR.keys.filter { Strings.ptPT[$0] == nil }
        #expect(missingInBR.isEmpty)
        #expect(missingInPT.isEmpty)
    }

    // The bracket failure a person sees is one plain sentence and one clear action.
    @Test func bracketFailureCopyStaysFriendlyInBothMarkets() {
        let state = AppState()
        let technical = ["AV", "EV", "bracket", "exposure", "bias", "AVFoundation"]

        state.selectRegion(.pt)
        #expect(state.t("camera.error.bracket") == "Não foi possível concluir esta fotografia.")
        #expect(state.t("camera.error.retry") == "Fotografar novamente")

        state.selectRegion(.br)
        #expect(state.t("camera.error.bracket") == "Não foi possível concluir esta foto.")
        #expect(state.t("camera.error.retry") == "Fotografar novamente")

        for region in [RegionCode.pt, .br] {
            state.selectRegion(region)
            for error in CameraError.allCases {
                let message = state.t(error.localizationKey)
                #expect(message != error.localizationKey)
                #expect(!technical.contains { message.contains($0) })
            }
        }

        state.selectRegion(.pt)
    }
}

/// Phase D2: real multi-exposure bracketing.
///
/// These tests lock the domain rules a bracket must obey — capability-driven profiles, EV 0,
/// deterministic ordering, one camera, one geometry, local-first persistence, atomic validation
/// and zero credit movement. Physical exposure quality is not testable here: that is verified on
/// a real iPhone, scene by scene.
@MainActor
@Suite(.serialized)
struct MultiExposureBracketTests {

    // MARK: - Capability detection & profile selection

    // A camera with the full ±8 EV envelope of a modern iPhone gets the whole ladder.
    @Test func fullLadderIsSelectedWhenTheDeviceSupportsIt() {
        let plan = CaptureProfileService.plan(for: Self.capabilities(min: -8, max: 8, bracket: 9))
        #expect(plan.profile == .full9)
        #expect(plan.exposureValues == [-4, -3, -2, -1, 0, 1, 2, 3, 4])
        #expect(plan.expectedFrameCount == 9)
        #expect(!plan.isSegmented)
    }

    // A narrower exposure range never fails the camera — it falls back, in order.
    @Test func profileFallsBackToTheWidestSupportedLadder() {
        let expectations: [(Double, CaptureProfile)] = [
            (8, .full9),
            (3.5, .standard7),
            (2.5, .compact5),
            (2.0, .compact5),
            // BASIC_3 is −2/0/+2: a ±1.5 EV camera cannot reach it and photographs one frame.
            (1.5, .single),
        ]
        for (range, expected) in expectations {
            let capabilities = Self.capabilities(min: -range, max: range, bracket: 9)
            #expect(CaptureProfileService.profile(for: capabilities) == expected)
        }
    }

    // BASIC_3 needs ±2 EV; a camera under that, or with no bracket at all, takes one photograph.
    @Test func singleProfileIsUsedWhenBracketingIsUnavailable() {
        let noBracket = Self.capabilities(min: -8, max: 8, bracket: 1, supportsBracket: false)
        #expect(CaptureProfileService.plan(for: noBracket).profile == .single)
        #expect(CaptureProfileService.plan(for: noBracket).exposureValues == [0])

        let noRange = Self.capabilities(min: -1, max: 1, bracket: 9)
        #expect(CaptureProfileService.profile(for: noRange) == .single)

        #expect(CaptureProfileService.plan(for: .unavailable).profile == .single)
    }

    // Every ladder is defined once and every bracket ladder contains the reference exposure.
    @Test func everyProfileCarriesTheReferenceExposure() {
        for profile in CaptureProfile.allCases {
            #expect(profile.includesReferenceExposure)
            #expect(profile.exposureValues.count == profile.expectedFrameCount)
            #expect(profile.exposureValues == profile.exposureValues.sorted())
        }
        #expect(CaptureProfile.full9.exposureValues.count == 9)
        #expect(CaptureProfile.standard7.exposureValues.count == 7)
        #expect(CaptureProfile.compact5.exposureValues.count == 5)
        #expect(CaptureProfile.basic3.exposureValues == [-2, 0, 2])
        #expect(CaptureProfile.single.exposureValues == [0])
    }

    // A camera that can only bracket three frames at a time still photographs the full ladder,
    // as consecutive requests — never more frames per request than the hardware allows.
    @Test func ladderIsSplitIntoSupportedBracketRequests() {
        let plan = CaptureProfileService.plan(for: Self.capabilities(min: -8, max: 8, bracket: 3))
        #expect(plan.profile == .full9)
        #expect(plan.isSegmented)
        #expect(plan.segments.allSatisfy { $0.count <= 3 })
        #expect(plan.exposureValues == CaptureProfile.full9.exposureValues)
        #expect(plan.exposureValues.contains(0))
        #expect(plan.expectedFrameCount == 9)
    }

    // MARK: - Bundle, manifest and validation

    // One shutter action produces one bundle: every frame, in order, with EV 0 and a checksum.
    @Test func bracketBundleIsPersistedLocallyAndValidates() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let frames = try Self.writeLadder(.full9, clientCaptureID: attempt.id)
        let manifest = Self.manifest(frames: frames, attempt: attempt, property: property)

        #expect(frames.count == 9)
        #expect(frames.map(\.sequenceIndex) == Array(0..<9))
        #expect(frames.map(\.requestedEV) == CaptureProfile.full9.exposureValues)
        #expect(frames.filter(\.isReferenceExposure).count == 1)
        #expect(Set(frames.map(\.checksum)).count == 9)
        #expect(frames.allSatisfy { $0.clientCaptureID == attempt.id })
        #expect(frames.allSatisfy { $0.uploadState == .pendingUpload })

        // Files are inside the app container, never in the user's photo library.
        for frame in frames {
            let path = CaptureBundleStore.path(for: frame)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(path.contains(attempt.id.uuidString))
            #expect(CaptureBundleStore.fileSize(frame) == frame.byteCount)
        }

        try CaptureBundleStore.writeManifest(manifest)
        #expect(CaptureBundleValidator.validate(manifest, deepVerify: true) == nil)

        let reloaded = try #require(CaptureBundleStore.readManifest(clientCaptureID: attempt.id))
        #expect(reloaded.captureProfile == .full9)
        #expect(reloaded.expectedFrameCount == 9)
        #expect(reloaded.actualFrameCount == 9)
        #expect(reloaded.orderedFrames.map(\.sequenceIndex) == Array(0..<9))
        #expect(reloaded.captureSource == .nativeReal)
        #expect(reloaded.hdrSource == .mock)
        #expect(reloaded.referenceFrame?.requestedEV == 0)
    }

    // An eight-frame FULL_9 is never accepted as a valid nine-frame capture.
    @Test func incompleteBracketIsRejected() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let frames = try Self.writeLadder(.full9, clientCaptureID: attempt.id).dropLast()
        var manifest = Self.manifest(frames: Array(frames), attempt: attempt, property: property)
        manifest.actualFrameCount = frames.count

        #expect(CaptureBundleValidator.validate(manifest) == .frameMissing)

        manifest.state = CameraError.frameMissing.bundleState
        #expect(manifest.state == .incomplete)
        #expect(!manifest.state.isValid)
    }

    // Without the reference exposure the bracket carries no usable HDR information.
    @Test func bracketWithoutReferenceExposureIsRejected() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        var frames = try Self.writeLadder(.basic3, clientCaptureID: attempt.id)
        frames[1].requestedEV = 1
        let manifest = Self.manifest(frames: frames, attempt: attempt, property: property, profile: .basic3)

        let referenceCount = manifest.frames.filter(\.isReferenceExposure).count
        #expect(referenceCount == 0)
        #expect(CaptureBundleValidator.validate(manifest) == .ev0Missing)
    }

    // One camera, one geometry, one orientation — anything else is not a bracket.
    @Test func mixedGeometryCameraOrOrientationIsRejected() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let frames = try Self.writeLadder(.basic3, clientCaptureID: attempt.id)

        var mixedSize = frames
        mixedSize[2].width += 40
        #expect(
            CaptureBundleValidator.validate(
                Self.manifest(frames: mixedSize, attempt: attempt, property: property, profile: .basic3)
            ) == .frameDimensionMismatch
        )

        var mixedOrientation = frames
        mixedOrientation[1].orientation = .landscapeLeft
        #expect(
            CaptureBundleValidator.validate(
                Self.manifest(frames: mixedOrientation, attempt: attempt, property: property, profile: .basic3)
            ) == .frameOrientationMismatch
        )

        var mixedCamera = frames
        mixedCamera[0].cameraID = "other-camera"
        #expect(
            CaptureBundleValidator.validate(
                Self.manifest(frames: mixedCamera, attempt: attempt, property: property, profile: .basic3)
            ) == .cameraChanged
        )
    }

    // Ordering is explicit: duplicated or shuffled indexes can never reach the HDR pipeline.
    @Test func frameOrderingIsDeterministic() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let frames = try Self.writeLadder(.compact5, clientCaptureID: attempt.id)
        let shuffled = Self.manifest(
            frames: frames.shuffled(), attempt: attempt, property: property, profile: .compact5
        )
        #expect(shuffled.orderedFrames.map(\.sequenceIndex) == Array(0..<5))
        #expect(shuffled.orderedFrames.map(\.requestedEV) == CaptureProfile.compact5.exposureValues)
        #expect(CaptureBundleValidator.validate(shuffled) == nil)

        var duplicated = frames
        duplicated[3].sequenceIndex = 2
        #expect(
            CaptureBundleValidator.validate(
                Self.manifest(frames: duplicated, attempt: attempt, property: property, profile: .compact5)
            ) == .manifestInvalid
        )
    }

    // Frames never cross attempts: capture A can never be completed with a frame from capture B.
    @Test func framesNeverCrossAttempts() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attemptA = try #require(state.beginCaptureAttempt(property: property, room: .living))
        state.endCaptureSequence()
        let attemptB = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attemptA.id)
            CaptureBundleStore.delete(clientCaptureID: attemptB.id)
        }

        var framesA = try Self.writeLadder(.basic3, clientCaptureID: attemptA.id)
        let framesB = try Self.writeLadder(.basic3, clientCaptureID: attemptB.id)
        framesA[2] = framesB[2]

        #expect(attemptA.id != attemptB.id)
        #expect(
            CaptureBundleValidator.validate(
                Self.manifest(frames: framesA, attempt: attemptA, property: property, profile: .basic3)
            ) == .manifestInvalid
        )
    }

    // MARK: - Registration, credits and recovery

    // A real bracket becomes exactly one capture, keeps its frames, and costs no credits.
    @Test func registeringABracketKeepsOneCaptureAndNoCreditMovement() throws {
        let state = AppState()
        state.preparationSeconds = 0.05
        let property = try #require(state.properties.first)
        let before = state.captures.count
        let balance = state.wallet.total
        let transactions = state.transactions.count

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }

        let frames = try Self.writeLadder(.full9, clientCaptureID: attempt.id)
        var manifest = Self.manifest(frames: frames, attempt: attempt, property: property)
        manifest.state = .localReady
        try CaptureBundleStore.writeManifest(manifest)

        #expect(state.captureStageLabel == "CAPTURING")
        state.beginLocalValidation()
        #expect(state.captureStageLabel == "LOCAL_VALIDATING")

        let capture = state.registerCapture(
            attempt: attempt,
            property: property,
            room: .living,
            frameCount: manifest.actualFrameCount,
            localFile: manifest.referenceFrame?.localPhotoFile,
            manifest: manifest
        )
        let replay = state.registerCapture(
            attempt: attempt,
            property: property,
            room: .living,
            frameCount: manifest.actualFrameCount,
            localFile: manifest.referenceFrame?.localPhotoFile,
            manifest: manifest
        )
        state.endCaptureSequence()

        #expect(capture.id == replay.id)
        #expect(state.captures.count == before + 1)
        #expect(capture.frameCount == 9)
        #expect(capture.frames.count == 9)
        #expect(capture.hasLocalOriginal)
        #expect(capture.captureSource == .nativeReal)
        // Pixels are real, the master is still simulated — the two stay distinct.
        #expect(capture.hdrSource == .mock)
        #expect(state.captureStageLabel == "LOCAL_READY")

        // Zero AI credits: photography is always included.
        #expect(state.wallet.total == balance)
        #expect(state.transactions.count == transactions)

        // The bundle now knows which capture it became.
        let stored = try #require(CaptureBundleStore.readManifest(clientCaptureID: attempt.id))
        #expect(stored.captureID == capture.id)
    }

    // A capture whose frames and manifest were safely stored survives a relaunch.
    @Test func persistedCaptureIsRestoredAfterRelaunch() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .bedroom))
        state.endCaptureSequence()
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }

        let frames = try Self.writeLadder(.compact5, clientCaptureID: attempt.id)
        var manifest = Self.manifest(
            frames: frames, attempt: attempt, property: property, profile: .compact5
        )
        manifest.state = .localReady
        manifest.completedAt = .now
        try CaptureBundleStore.writeManifest(manifest)

        #expect(!state.captures.contains { $0.clientCaptureID == attempt.id })
        state.restorePendingCaptures()

        let restored = try #require(state.captures.first { $0.clientCaptureID == attempt.id })
        #expect(restored.isPendingSync)
        #expect(restored.frameCount == 5)
        #expect(restored.room == .bedroom)
        #expect(restored.propertyID == property.id)
        #expect(restored.hasLocalOriginal)

        // Restoring twice never duplicates a capture.
        state.restorePendingCaptures()
        #expect(state.captures.filter { $0.clientCaptureID == attempt.id }.count == 1)
    }

    // An interrupted bracket is evidence, not a capture: it is never restored.
    @Test func interruptedBundleIsNeverRestored() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .office))
        state.endCaptureSequence()
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }

        let frames = try Self.writeLadder(.basic3, clientCaptureID: attempt.id)
        var manifest = Self.manifest(
            frames: Array(frames.prefix(2)), attempt: attempt, property: property, profile: .basic3
        )
        manifest.actualFrameCount = 2
        manifest.state = CameraError.captureInterrupted.bundleState
        manifest.failureCode = CameraError.captureInterrupted.code
        try CaptureBundleStore.writeManifest(manifest)

        state.restorePendingCaptures()
        #expect(!state.captures.contains { $0.clientCaptureID == attempt.id })

        let stored = try #require(CaptureBundleStore.readManifest(clientCaptureID: attempt.id))
        #expect(stored.state == .interrupted)
        #expect(stored.failureCode == "CAPTURE_INTERRUPTED")
        // Debugging evidence is kept: nothing is deleted eagerly during development.
        #expect(CaptureBundleStore.cleanupIncomplete(olderThan: 60 * 60 * 24) == 0)
    }

    // MARK: - Helpers

    private static func capabilities(
        min: Double,
        max: Double,
        bracket: Int,
        supportsBracket: Bool = true
    ) -> CameraExposureCapabilities {
        CameraExposureCapabilities(
            deviceModel: "iPhone16,1",
            systemVersion: "iOS 26.0",
            activeLens: "Rear Wide",
            cameraID: "test-camera",
            activeFormat: "4032×3024",
            minExposureBias: min,
            maxExposureBias: max,
            maxBracketCount: bracket,
            supportsBracketCapture: supportsBracket && bracket >= 2,
            supportsExposureLock: true,
            supportsCustomExposure: true,
            supportsFocusLock: true,
            supportsWhiteBalanceLock: true,
            supportsLensStabilization: true
        )
    }

    /// Writes a real ladder of files, one visibly different image per exposure.
    private static func writeLadder(
        _ profile: CaptureProfile,
        clientCaptureID: UUID
    ) throws -> [CaptureFrame] {
        try profile.exposureValues.enumerated().map { index, ev in
            let brightness = 0.5 + ev * 0.1
            var frame = try CaptureBundleStore.writeFrame(
                photoData: jpeg(brightness: brightness),
                clientCaptureID: clientCaptureID,
                sequenceIndex: index,
                requestedEV: ev,
                orientation: .portrait,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
            frame.actualExposureBias = ev
            frame.iso = 100 * Double(index + 1)
            frame.exposureDurationSeconds = 1.0 / Double(120 - index * 10)
            frame.aperture = 1.78
            return frame
        }
    }

    private static func manifest(
        frames: [CaptureFrame],
        attempt: CaptureAttempt,
        property: Property,
        profile: CaptureProfile = .full9
    ) -> CaptureManifest {
        CaptureManifest(
            captureID: nil,
            clientCaptureID: attempt.id,
            organizationID: "Test Workspace",
            propertyID: property.id,
            roomID: attempt.room.rawValue,
            device: "iPhone16,1",
            iOSVersion: "iOS 26.0",
            appVersion: "1.0.0 (1)",
            cameraID: "test-camera",
            lensType: "Rear Wide",
            captureProfile: profile,
            expectedFrameCount: profile.expectedFrameCount,
            actualFrameCount: frames.count,
            segmentCount: 1,
            orientation: .portrait,
            focusLockSucceeded: .succeeded,
            whiteBalanceLockSucceeded: .succeeded,
            state: .localValidating,
            startedAt: attempt.startedAt,
            completedAt: nil,
            firstFrameSeconds: 0.2,
            bracketSeconds: 1.4,
            persistSeconds: 0.3,
            manifestSeconds: 0.02,
            frames: frames
        )
    }

    /// A 4:3 image, dark for negative exposures and bright for positive ones.
    private static func jpeg(brightness: Double) -> Data {
        let size = CGSize(width: 400, height: 300)
        let level = Swift.max(0.02, Swift.min(0.98, brightness))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: level, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// Phase D3: stability, focus, exposure and physical camera calibration.
///
/// These tests lock the deterministic parts — rolling-window stability, level math, calibration
/// resolution and sanitising, fractional ladders, quality grading, storage preflight, histogram
/// analysis and zero credit movement. Real sensor behaviour, real focus and real white balance
/// can only be judged on a physical iPhone with the standard test scenes.
@MainActor
@Suite(.serialized)
struct CameraCalibrationTests {

    // MARK: - Stability

    // One calm reading is not enough: the window must stay calm for the minimum duration.
    @Test func stabilityNeedsACalmWindowBeforeReportingStable() {
        var analyzer = StabilityAnalyzer(thresholds: .default, levelToleranceDegrees: 1.5)
        var reading = StabilityReading.idle
        var time = 0.0
        while time < 0.3 {
            reading = analyzer.ingest(Self.sample(time))
            time += 1.0 / 30.0
        }
        #expect(reading.state == .stabilizing)
        while time < 0.6 {
            reading = analyzer.ingest(Self.sample(time))
            time += 1.0 / 30.0
        }
        #expect(reading.state == .stable)
        #expect(reading.score > 0.99)
        #expect(!reading.isSevere)
    }

    // Movement makes it unstable at once; a hard jolt is severe and may hold the shutter.
    @Test func movementIsUnstableAndAJoltIsSevere() {
        var analyzer = StabilityAnalyzer(thresholds: .default, levelToleranceDegrees: 1.5)
        var time = 0.0
        for _ in 0..<20 {
            _ = analyzer.ingest(Self.sample(time))
            time += 1.0 / 30.0
        }
        let moving = analyzer.ingest(Self.sample(time, rotation: 0.5))
        #expect(moving.state == .unstable)
        #expect(!moving.isSevere)
        #expect(moving.score < 0.5)

        time += 1.0 / 30.0
        let jolt = analyzer.ingest(Self.sample(time, rotation: 2.0))
        #expect(jolt.isSevere)
        #expect(jolt.state == .unstable)
        #expect(StabilityThresholds.default.blockCaptureWhenSevere)
    }

    @Test func stabilityScoreIsNormalised() {
        #expect(StabilityAnalyzer.score(ratio: 0) == 1)
        #expect(StabilityAnalyzer.score(ratio: 1) == 0.5)
        #expect(StabilityAnalyzer.score(ratio: 2) == 0)
        #expect(StabilityAnalyzer.score(ratio: 40) == 0)
        #expect(StabilityAnalyzer.score(ratio: .nan) == 0)
    }

    // Roll is measured against the nearest upright or landscape orientation; pitch is camera tilt.
    @Test func levelIsCorrectInPortraitAndLandscape() {
        let upright = StabilityAnalyzer.level(gravityX: 0, gravityY: -1, gravityZ: 0)
        #expect(abs(upright.roll) < 0.001)
        #expect(abs(upright.pitch) < 0.001)

        let radians = 3.0 * .pi / 180
        let tilted = StabilityAnalyzer.level(gravityX: sin(radians), gravityY: -cos(radians), gravityZ: 0)
        #expect(abs(tilted.roll - 3) < 0.01)

        let landscape = StabilityAnalyzer.level(gravityX: -cos(radians), gravityY: -sin(radians), gravityZ: 0)
        #expect(abs(landscape.horizon + 87) < 0.01)
        #expect(abs(landscape.roll - 3) < 0.01)

        let pitchRadians = 10.0 * .pi / 180
        let pitched = StabilityAnalyzer.level(gravityX: 0, gravityY: -cos(pitchRadians), gravityZ: -sin(pitchRadians))
        #expect(abs(pitched.pitch - 10) < 0.01)

        var analyzer = StabilityAnalyzer(thresholds: .default, levelToleranceDegrees: 1.5)
        let level = analyzer.ingest(Self.sample(0, gravity: (sin(radians), -cos(radians), 0)))
        #expect(!level.isLevel)
    }

    // Motion during a bracket is flagged — the frames are kept for the future HDR engine.
    @Test func bracketMotionIsAssessedNotDeleted() {
        var analyzer = StabilityAnalyzer(thresholds: .default, levelToleranceDegrees: 1.5)
        var time = 0.0
        var reading = StabilityReading.idle
        for _ in 0..<20 {
            reading = analyzer.ingest(Self.sample(time))
            time += 1.0 / 30.0
        }

        var calm = CaptureMotionRecorder(before: reading)
        for _ in 0..<10 {
            let sample = Self.sample(time)
            calm.record(sample: sample, reading: analyzer.ingest(sample))
            time += 1.0 / 30.0
        }
        let calmSnapshot = calm.snapshot(sensorAvailable: true, thresholds: .default)
        #expect(calmSnapshot.assessment == .none)
        #expect(calmSnapshot.rollAngleAtCapture != nil)
        #expect((calmSnapshot.stabilityScore ?? 0) > 0.9)

        var shaken = CaptureMotionRecorder(before: reading)
        let jolt = Self.sample(time, rotation: 2.5)
        shaken.record(sample: jolt, reading: analyzer.ingest(jolt))
        let shakenSnapshot = shaken.snapshot(sensorAvailable: true, thresholds: .default)
        #expect(shakenSnapshot.assessment == .severe)
        #expect((shakenSnapshot.maxRotationDuringCapture ?? 0) >= 2.5)

        #expect(calm.snapshot(sensorAvailable: false, thresholds: .default).assessment == .unavailable)
    }

    // MARK: - Calibration

    @Test func calibrationResolvesTheMostSpecificProfile() {
        var family = CameraCalibrationProfile.generic
        family.id = "iphone16-family"
        family.deviceModel = "iPhone16,"
        var exact = CameraCalibrationProfile.generic
        exact.id = "iphone16-1"
        exact.deviceModel = "iPhone16,1"
        exact.status = .testing
        var pinned = exact
        pinned.id = "iphone16-1-cam"
        pinned.cameraUniqueID = "camera-A"
        var future = CameraCalibrationProfile.generic
        future.id = "future-os"
        future.deviceModel = "iPhone16,1"
        future.osVersionRange = OSVersionRange(minimum: "30.0", maximum: nil)
        let profiles = [CameraCalibrationProfile.generic, family, exact, pinned, future]

        #expect(CameraCalibrationCatalog.resolve(deviceModel: "iPhone15,2", systemVersion: "18.2", profiles: profiles).id == "generic")
        #expect(CameraCalibrationCatalog.resolve(deviceModel: "iPhone16,2", systemVersion: "18.2", profiles: profiles).id == "iphone16-family")
        #expect(CameraCalibrationCatalog.resolve(deviceModel: "iPhone16,1", systemVersion: "18.2", profiles: profiles).id == "iphone16-1")
        #expect(CameraCalibrationCatalog.resolve(deviceModel: "iPhone16,1", systemVersion: "26.0", cameraUniqueID: "camera-A", profiles: profiles).id == "iphone16-1-cam")
        // Nothing ships as CALIBRATED before physical QA.
        #expect(CameraCalibrationCatalog.bundled.allSatisfy { $0.status != .calibrated })
    }

    // Remote calibration is configuration only — every value is clamped, bad ladders dropped.
    @Test func remoteCalibrationIsSanitised() throws {
        var hostile = CameraCalibrationProfile.generic
        hostile.id = "remote"
        hostile.exposureValues = [-3, -1, 1, 3]
        hostile.levelToleranceDegrees = 90
        hostile.focusStrategy.settleTimeoutMs = 60_000
        hostile.stabilityThresholds.stabilityWindowMs = -5
        hostile.profileVersion = 0

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CalibrationPayload(schemaVersion: 1, issuedAt: .now, profiles: [hostile]))
        let safe = try #require(try CameraCalibrationCatalog.decode(data).first)
        #expect(safe.exposureValues == nil)
        #expect(safe.levelToleranceDegrees == 10)
        #expect(safe.focusStrategy.settleTimeoutMs == 2500)
        #expect(safe.stabilityThresholds.stabilityWindowMs == 150)
        #expect(safe.profileVersion == 1)

        let unsupported = try encoder.encode(CalibrationPayload(schemaVersion: 99, issuedAt: .now, profiles: [hostile]))
        #expect(throws: CalibrationPayloadError.self) { try CameraCalibrationCatalog.decode(unsupported) }

        #expect(CameraCalibrationCatalog.sanitizeLadder([0.5, -0.5, 0]) == [-0.5, 0, 0.5])
        #expect(CameraCalibrationCatalog.sanitizeLadder([-9, 0, 9]) == nil)
        #expect(CameraCalibrationCatalog.sanitizeLadder([-1, 0, 0, 1]) == nil)
    }

    // A device-specific fractional ladder is used when the hardware reaches every value.
    @Test func fractionalDeviceLadderIsUsedWhenSupported() {
        var calibration = CameraCalibrationProfile.generic
        calibration.exposureValues = [-2.5, -1.5, -0.5, 0, 0.5, 1.5, 2.5]

        let plan = CaptureProfileService.plan(for: Self.capabilities(range: 8, bracket: 9), calibration: calibration)
        #expect(plan.exposureValues == [-2.5, -1.5, -0.5, 0, 0.5, 1.5, 2.5])
        #expect(plan.ladderSource == .deviceCalibration)
        #expect(plan.profile == .standard7)
        #expect(plan.calibrationVersion == calibration.versionLabel)

        let segmented = CaptureProfileService.plan(for: Self.capabilities(range: 8, bracket: 3), calibration: calibration)
        #expect(segmented.isSegmented)
        #expect(segmented.segments.allSatisfy { $0.count <= 3 })
        #expect(segmented.exposureValues == plan.exposureValues)

        // A ladder the camera cannot reach falls back to the standard profiles.
        let narrow = CaptureProfileService.plan(for: Self.capabilities(range: 2, bracket: 9), calibration: calibration)
        #expect(narrow.ladderSource == .standardProfile)
        #expect(narrow.profile == .compact5)
    }

    @Test func calibrationCanCapOrDisableBracketing() {
        var capped = CameraCalibrationProfile.generic
        capped.captureProfile = .compact5
        #expect(CaptureProfileService.plan(for: Self.capabilities(range: 8, bracket: 9), calibration: capped).profile == .compact5)

        var disabled = CameraCalibrationProfile.generic
        disabled.status = .disabled
        #expect(CaptureProfileService.plan(for: Self.capabilities(range: 8, bracket: 9), calibration: disabled).profile == .single)
    }

    @Test func evLabelsKeepSignAndFractions() {
        #expect(CaptureProfile.evLabel(-4) == "-4")
        #expect(CaptureProfile.evLabel(0) == "0")
        #expect(CaptureProfile.evLabel(2) == "+2")
        #expect(CaptureProfile.evLabel(-0.5) == "-0.5")
        #expect(CaptureProfile.evLabel(2.5) == "+2.5")
        #expect(CaptureProfile.evLabel(0.25) == "+0.25")
    }

    // A fractional ladder persists, validates and keeps distinct file names.
    @Test func fractionalBracketBundleValidates() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let ladder: [Double] = [-1.5, 0, 1.5]
        let frames = try ladder.enumerated().map { index, ev in
            try CaptureBundleStore.writeFrame(
                photoData: Self.jpeg(brightness: 0.5 + ev * 0.1),
                clientCaptureID: attempt.id,
                sequenceIndex: index,
                requestedEV: ev,
                orientation: .landscapeLeft,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
        }
        #expect(Set(frames.map(\.fileName)).count == 3)
        #expect(frames[0].fileName.contains("-1.5"))
        #expect(frames[2].fileName.contains("+1.5"))

        var manifest = Self.manifest(frames: frames, attempt: attempt, property: property, profile: .basic3)
        manifest.requestedExposureValues = ladder
        manifest.orientation = .landscapeLeft
        #expect(CaptureBundleValidator.validate(manifest) == nil)

        // The standard BASIC_3 ladder (-2/0/+2) would not match these frames.
        manifest.requestedExposureValues = nil
        #expect(CaptureBundleValidator.validate(manifest) == .manifestInvalid)
    }

    // A bundle written before D3 (schema v1, no quality report) is still a valid capture.
    @Test func schemaV1BundlesRemainValid() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let frames = try CaptureProfile.basic3.exposureValues.enumerated().map { index, ev in
            try CaptureBundleStore.writeFrame(
                photoData: Self.jpeg(brightness: 0.5 + ev * 0.1),
                clientCaptureID: attempt.id,
                sequenceIndex: index,
                requestedEV: ev,
                orientation: .portrait,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
        }
        var manifest = Self.manifest(frames: frames, attempt: attempt, property: property, profile: .basic3)
        manifest.schemaVersion = 1
        try CaptureBundleStore.writeManifest(manifest)

        let reloaded = try #require(CaptureBundleStore.readManifest(clientCaptureID: attempt.id))
        #expect(reloaded.quality == nil)
        #expect(reloaded.requestedLadder == [-2, 0, 2])
        #expect(CaptureBundleValidator.validate(reloaded) == nil)
    }

    // MARK: - Quality

    @Test func qualityClassFollowsLocksMotionAndConsistency() {
        let id = UUID()
        let wb = WhiteBalanceReading(redGain: 1.9, greenGain: 1.0, blueGain: 2.1, temperature: 5200, tint: 2)
        let steady = (0..<3).map { Self.frame(index: $0, lens: 0.42, wb: wb, clientCaptureID: id) }

        let good = CaptureQualityAnalyzer.report(Self.qualityInput(frames: steady))
        #expect(good.qualityClass == .good)
        #expect(good.qualityReasons.isEmpty)
        #expect(good.focusLockSucceeded && good.whiteBalanceLockSucceeded && good.exposureReferenceEstablished)

        var shifted = steady
        shifted[2].lensPosition = 0.55
        let focusShift = CaptureQualityAnalyzer.report(Self.qualityInput(frames: shifted))
        #expect(focusShift.focusShiftDetected)
        #expect(focusShift.qualityClass == .poor)

        var tinted = steady
        tinted[1].whiteBalance = WhiteBalanceReading(redGain: 1.5, greenGain: 1.0, blueGain: 2.4, temperature: 4300, tint: 2)
        let colour = CaptureQualityAnalyzer.report(Self.qualityInput(frames: tinted))
        #expect(colour.whiteBalanceVariation)
        #expect(colour.qualityClass == .poor)
        #expect(colour.qualityReasons.contains("WHITE_BALANCE_VARIATION"))

        var minorMotion = Self.stableMotion
        minorMotion.assessment = .warning
        #expect(CaptureQualityAnalyzer.report(Self.qualityInput(frames: steady, motion: minorMotion)).qualityClass == .warning)

        var severe = Self.stableMotion
        severe.assessment = .severe
        #expect(CaptureQualityAnalyzer.report(Self.qualityInput(frames: steady, motion: severe)).qualityClass == .poor)

        var timeout = Self.goodPreparation
        timeout.focusTimeout = true
        let timedOut = CaptureQualityAnalyzer.report(Self.qualityInput(frames: steady, preparation: timeout))
        #expect(timedOut.qualityClass == .warning)
        #expect(timedOut.qualityReasons.contains("FOCUS_TIMEOUT"))

        #expect(CaptureQualityAnalyzer.report(Self.qualityInput(frames: steady, motion: .unavailable)).qualityClass == .warning)
    }

    @Test func frameIntervalsComeFromSensorTimestamps() throws {
        let id = UUID()
        var frames = (0..<3).map { Self.frame(index: $0, lens: 0.4, wb: nil, clientCaptureID: id) }
        frames[0].sensorTimestampSeconds = 100.0
        frames[1].sensorTimestampSeconds = 100.12
        frames[2].sensorTimestampSeconds = 100.25

        let report = CaptureQualityAnalyzer.report(Self.qualityInput(frames: frames))
        #expect(report.frameIntervalsMs.count == 2)
        #expect(abs(report.frameIntervalsMs[0] - 120) < 0.5)
        #expect(abs(report.frameIntervalsMs[1] - 130) < 0.5)
        #expect(abs((report.exposureSpanMs ?? 0) - 250) < 0.5)
    }

    // The full lifecycle stores every D3 metric in the manifest — and moves zero credits.
    @Test func finalizedBracketCarriesTheQualityReportAndCostsNothing() throws {
        let state = AppState()
        let property = try #require(state.properties.first)
        let balance = state.wallet.total
        let transactions = state.transactions.count
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer {
            state.endCaptureSequence()
            CaptureBundleStore.delete(clientCaptureID: attempt.id)
        }

        let plan = CaptureProfileService.plan(for: Self.capabilities(range: 8, bracket: 9))
        let frames = try plan.exposureValues.enumerated().map { index, ev -> CaptureFrame in
            var frame = try CaptureBundleStore.writeFrame(
                photoData: Self.jpeg(brightness: 0.5 + ev * 0.1),
                clientCaptureID: attempt.id,
                sequenceIndex: index,
                requestedEV: ev,
                orientation: .portrait,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
            frame.lensPosition = 0.4
            frame.sensorTimestampSeconds = 50 + Double(index) * 0.11
            return frame
        }
        let result = BracketCaptureResult(
            plan: plan,
            frames: frames,
            orientation: .portrait,
            cameraID: "test-camera",
            lensType: "Rear Wide",
            deviceModel: "iPhone16,1",
            systemVersion: "iOS 26.0",
            preparation: Self.goodPreparation,
            lens: nil,
            calibration: .generic,
            startedAt: .now,
            completedAt: .now,
            firstFrameSeconds: 0.3,
            bracketSeconds: 1.4,
            persistSeconds: 0.2,
            tapToCaptureStartMs: 210,
            bracketDurationMs: 980
        )
        let tag = CameraQATag(scene: .livingRoomWindow, condition: .tripod, note: nil)
        let manifest = try CaptureManifestBuilder.finalize(
            result: result,
            attempt: attempt,
            property: property,
            organizationID: "Test Workspace",
            context: CaptureRecordingContext(motion: Self.stableMotion, capturedOffline: true, qaTag: tag)
        )

        #expect(manifest.state == .localReady)
        #expect(manifest.schemaVersion == 2)
        let quality = try #require(manifest.quality)
        #expect(quality.qualityClass == .good)
        #expect(quality.bracketDurationMs == 980)
        #expect(quality.tapToCaptureStartMs == 210)
        #expect(quality.frameIntervalsMs.count == 8)
        #expect(quality.rollAngle == Self.stableMotion.rollAngleAtCapture)
        #expect(quality.pitchAngle == Self.stableMotion.pitchAngleAtCapture)
        #expect(quality.stabilityScore == Self.stableMotion.stabilityDuringCapture)
        #expect(quality.capturedOffline)
        #expect(quality.deviceCaptureProfileVersion == CameraCalibrationProfile.generic.versionLabel)
        #expect(quality.calibrationStatus == .untested)

        let stored = try #require(CaptureBundleStore.readManifest(clientCaptureID: attempt.id))
        #expect(stored.quality?.qualityClass == .good)
        #expect(stored.qaTag == tag)
        #expect(stored.requestedLadder == plan.exposureValues)

        // Calibration, stability analysis, bracketing and locks consume zero AI credits.
        #expect(state.wallet.total == balance)
        #expect(state.transactions.count == transactions)
    }

    // MARK: - Storage, analysis, session

    @Test func storagePreflightRefusesABracketThatCannotFinish() {
        let nine = CaptureStoragePolicy.requiredBytes(frameCount: 9, averageFrameBytes: 6_000_000)
        #expect(nine > CaptureStoragePolicy.requiredBytes(frameCount: 3, averageFrameBytes: 6_000_000))
        #expect(!CaptureStoragePolicy.hasRoom(frameCount: 9, averageFrameBytes: 6_000_000, availableBytes: 50_000_000))
        #expect(CaptureStoragePolicy.hasRoom(frameCount: 9, averageFrameBytes: 6_000_000, availableBytes: 10_000_000_000))
        // Unknown free space never blocks photography on a guess.
        #expect(CaptureStoragePolicy.hasRoom(frameCount: 9, averageFrameBytes: nil, availableBytes: nil))

        let state = AppState()
        state.devSimulateLowStorage = true
        let simulated = state.devAvailableBytesOverride
        #expect(!CaptureStoragePolicy.hasRoom(frameCount: 9, averageFrameBytes: nil, availableBytes: simulated))
    }

    @Test func histogramAndClippingAreMeasured() throws {
        let half = [UInt8](repeating: 0, count: 500) + [UInt8](repeating: 255, count: 500)
        let analysis = try #require(FrameExposureAnalyzer.analyze(luminance: half))
        #expect(abs(analysis.highlightClippingPercent - 50) < 0.001)
        #expect(abs(analysis.shadowClippingPercent - 50) < 0.001)
        #expect(abs(analysis.histogram.reduce(0, +) - 1) < 0.0001)
        #expect(analysis.histogram.count == FrameExposureAnalyzer.binCount)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ve-analysis-\(UUID().uuidString).jpg")
        try Self.jpeg(brightness: 0.5).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = try #require(FrameExposureAnalyzer.analyze(url: url))
        #expect(abs(mid.meanLuminance - 0.5) < 0.08)
        #expect(mid.highlightClippingPercent == 0)
        #expect(mid.shadowClippingPercent == 0)
    }

    @Test func dynamicRangeReportFindsRecoveryAndRedundancy() throws {
        func entry(_ ev: Double, mean: Double, highlight: Double, shadow: Double) -> BracketDynamicRangeReport.Entry {
            BracketDynamicRangeReport.Entry(
                requestedEV: ev,
                analysis: FrameExposureAnalysis(histogram: [], meanLuminance: mean, highlightClippingPercent: highlight, shadowClippingPercent: shadow)
            )
        }
        let useful = try #require(BracketDynamicRangeReport.evaluate([
            entry(-2, mean: 0.18, highlight: 0.1, shadow: 30),
            entry(0, mean: 0.45, highlight: 6, shadow: 8),
            entry(2, mean: 0.75, highlight: 25, shadow: 0.2),
        ]))
        #expect(useful.darkestRecoversHighlights)
        #expect(useful.brightestRecoversShadows)
        #expect(useful.adjacentExposuresDistinct)
        #expect(useful.verdict == "USEFUL_RANGE")

        let redundant = try #require(BracketDynamicRangeReport.evaluate([
            entry(-4, mean: 0.01, highlight: 0, shadow: 90),
            entry(-3, mean: 0.015, highlight: 0, shadow: 85),
            entry(0, mean: 0.45, highlight: 4, shadow: 6),
            entry(3, mean: 0.8, highlight: 30, shadow: 0.1),
        ]))
        #expect(redundant.redundantPairs == [[-4, -3]])
        #expect(redundant.unusableDarkExtreme)
        #expect(redundant.verdict == "REDUNDANT_EXTREMES")
    }

    @Test func untaggedCapturesNeverReachTheQADataset() {
        #expect(throws: CameraQADatasetExporter.ExportError.self) {
            try CameraQADatasetExporter.export([])
        }
    }

    @Test func sessionMetricsCountDuplicateAttempts() {
        let state = AppState()
        let id = UUID()
        let run = CaptureRunMetric(
            clientCaptureID: id, at: .now, succeeded: true, frameCount: 9, bracketDurationMs: 900,
            tapToCaptureStartMs: 200, memoryFootprintMB: 120, thermalState: "NOMINAL", qualityClass: .good, failureCode: nil
        )
        state.recordCaptureRun(run)
        var other = run
        other.clientCaptureID = UUID()
        state.recordCaptureRun(other)
        #expect(state.cameraDiagnostics.duplicateAttemptCount == 0)
        state.recordCaptureRun(run)
        #expect(state.cameraDiagnostics.duplicateAttemptCount == 1)
    }

    // Background sync yields while a new bracket is being photographed.
    @Test func syncYieldsWhileCapturing() async throws {
        let state = AppState()
        state.preparationSeconds = 0.05
        let property = try #require(state.properties.first)
        let first = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let capture = state.registerCapture(attempt: first, property: property, room: .living, frameCount: 9)
        state.endCaptureSequence()

        _ = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(state.captures.first { $0.id == capture.id }?.jobState != .ready)

        state.endCaptureSequence()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(state.captures.first { $0.id == capture.id }?.jobState == .ready)
    }

    @Test func newCameraErrorsHaveFriendlyCopy() {
        let state = AppState()
        for region in [RegionCode.pt, .br] {
            state.selectRegion(region)
            #expect(state.t(CameraError.focusTimeout.localizationKey) != CameraError.focusTimeout.localizationKey)
            #expect(state.t(CameraError.insufficientStorage.localizationKey) != CameraError.insufficientStorage.localizationKey)
            #expect(state.t("camera.hold.steady") == "Mantenha estável")
        }
        state.selectRegion(.pt)
        #expect(state.t("camera.stabilizing") == "A estabilizar")
        state.selectRegion(.br)
        #expect(state.t("camera.stabilizing") == "Estabilizando")
        state.selectRegion(.pt)
    }

    // MARK: - Helpers

    private static func sample(
        _ time: Double,
        rotation: Double = 0,
        acceleration: Double = 0,
        gravity: (Double, Double, Double) = (0, -1, 0)
    ) -> MotionSample {
        MotionSample(
            timestamp: time,
            rotationX: rotation, rotationY: 0, rotationZ: 0,
            accelerationX: acceleration, accelerationY: 0, accelerationZ: 0,
            gravityX: gravity.0, gravityY: gravity.1, gravityZ: gravity.2
        )
    }

    private static let stableMotion = CaptureMotionSnapshot(
        sensorAvailable: true,
        stabilityBeforeCapture: 0.95,
        stateBeforeCapture: .stable,
        stabilityDuringCapture: 0.92,
        minimumStabilityDuringCapture: 0.85,
        stabilityAtEnd: 0.9,
        maxRotationDuringCapture: 0.05,
        maxAccelerationDuringCapture: 0.01,
        rollAngleAtCapture: 0.4,
        pitchAngleAtCapture: -2.0,
        wasLevelAtCapture: true,
        sampleCount: 40,
        assessment: .none
    )

    private static let goodPreparation = SequencePreparation(
        focusStatus: .locked,
        focusLock: .succeeded,
        focusTimeout: false,
        whiteBalanceLock: .succeeded,
        whiteBalanceReference: nil,
        exposureReferenceEstablished: true,
        meteringStrategy: .centerWeighted,
        preparationMs: 180
    )

    private static func qualityInput(
        frames: [CaptureFrame],
        motion: CaptureMotionSnapshot = stableMotion,
        preparation: SequencePreparation = goodPreparation
    ) -> CaptureQualityInput {
        CaptureQualityInput(
            frames: frames,
            motion: motion,
            preparation: preparation,
            calibration: .generic,
            requestedExposureValues: frames.map(\.requestedEV),
            ladderSource: .standardProfile,
            lens: nil,
            tapToCaptureStartMs: 200,
            bracketDurationMs: 900,
            capturedOffline: false,
            thermalState: "NOMINAL",
            memoryFootprintMB: 120
        )
    }

    private static func frame(index: Int, lens: Double?, wb: WhiteBalanceReading?, clientCaptureID: UUID) -> CaptureFrame {
        var frame = CaptureFrame(
            clientCaptureID: clientCaptureID,
            sequenceIndex: index,
            requestedEV: Double(index - 1) * 2,
            width: 400,
            height: 300,
            exifOrientation: 6,
            orientation: .portrait,
            cameraID: "test-camera",
            lensType: "Rear Wide",
            fileName: "frame_\(index).jpg",
            byteCount: 100,
            checksum: "checksum-\(index)",
            capturedAt: Date(timeIntervalSinceReferenceDate: 1000 + Double(index) * 0.1)
        )
        frame.lensPosition = lens
        frame.whiteBalance = wb
        return frame
    }

    private static func capabilities(range: Double, bracket: Int) -> CameraExposureCapabilities {
        CameraExposureCapabilities(
            deviceModel: "iPhone16,1",
            systemVersion: "iOS 26.0",
            activeLens: "Rear Wide",
            cameraID: "test-camera",
            activeFormat: "4032×3024",
            minExposureBias: -range,
            maxExposureBias: range,
            maxBracketCount: bracket,
            supportsBracketCapture: bracket >= 2,
            supportsExposureLock: true,
            supportsCustomExposure: true,
            supportsFocusLock: true,
            supportsWhiteBalanceLock: true,
            supportsLensStabilization: true
        )
    }

    private static func manifest(
        frames: [CaptureFrame],
        attempt: CaptureAttempt,
        property: Property,
        profile: CaptureProfile
    ) -> CaptureManifest {
        CaptureManifest(
            captureID: nil,
            clientCaptureID: attempt.id,
            organizationID: "Test Workspace",
            propertyID: property.id,
            roomID: attempt.room.rawValue,
            device: "iPhone16,1",
            iOSVersion: "iOS 26.0",
            appVersion: "1.0.0 (1)",
            cameraID: "test-camera",
            lensType: "Rear Wide",
            captureProfile: profile,
            expectedFrameCount: frames.count,
            actualFrameCount: frames.count,
            segmentCount: 1,
            orientation: .portrait,
            focusLockSucceeded: .succeeded,
            whiteBalanceLockSucceeded: .succeeded,
            state: .localValidating,
            startedAt: attempt.startedAt,
            completedAt: nil,
            frames: frames
        )
    }

    private static func jpeg(brightness: Double) -> Data {
        let size = CGSize(width: 400, height: 300)
        let level = Swift.max(0.02, Swift.min(0.98, brightness))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: level, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// Real capture audit and the first real HDR pipeline.
///
/// Physical bracket behaviour can only be proven on an iPhone; these tests lock the rules the
/// audit and the pipeline must obey — real files only, unique hashes, truthful profile naming,
/// a verified master file, the original untouched, READY only with the file, and 0 credits.
@MainActor
@Suite(.serialized)
struct RealHDRPipelineTests {

    // MARK: - Bracket audit

    // Nine real, unique, materially different files with nine callbacks are a truthful FULL_9.
    @Test func truthfulFullLadderIsReportedAsSuch() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(.full9, clientCaptureID: id)
        let plan = BracketPlan(profile: .full9, segments: [[-4, -3, -2, -1, 0], [1, 2, 3, 4]], reason: "")

        let audit = BracketAuditor.audit(frames: frames, plan: plan, evidence: Self.evidence(9, requests: [5, 4]))

        #expect(audit.callbacks == 9)
        #expect(audit.nativeRequests == 2)
        #expect(audit.persistedFiles == 9)
        #expect(audit.verifiedChecksums == 9)
        #expect(audit.uniqueHashes == 9)
        #expect(audit.realFrames == 9)
        #expect(audit.ev0Frames == 1)
        #expect(audit.distinctExposureLevels == 9)
        #expect(audit.isTruthful)
        #expect(audit.validatedProfile == .full9)
        #expect(audit.supportsHDR)
    }

    // Requested count is never used as captured count: a byte-identical pair is one real frame,
    // the profile is not called FULL_9, and the bundle is refused.
    @Test func duplicateFilesAreNeverCountedAsRealFrames() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        var frames = try Self.writeScene(.full9, clientCaptureID: id)
        // Overwrite +4 with the +3 bytes, as an index overwrite would.
        let duplicate = try #require(CaptureBundleStore.loadData(frames[7]))
        frames[8] = try CaptureBundleStore.writeFrame(
            photoData: duplicate, clientCaptureID: id, sequenceIndex: 8, requestedEV: 4,
            orientation: .portrait, cameraID: "test-camera", lensType: "Rear Wide"
        )
        frames[8].exposureDurationSeconds = frames[7].exposureDurationSeconds
        frames[8].iso = frames[7].iso

        let audit = BracketAuditor.audit(frames: frames, plan: Self.plan(.full9), evidence: Self.evidence(9, requests: [9]))

        #expect(audit.uniqueHashes == 8)
        #expect(audit.realFrames == 7)
        #expect(!audit.isTruthful)
        #expect(audit.validatedProfile != .full9)

        let manifest = Self.manifest(frames: frames, clientCaptureID: id, profile: .full9)
        #expect(CaptureBundleValidator.validate(manifest) == .duplicateFrame)
    }

    // Two requested EVs the sensor photographed identically are reported, and the profile is
    // named by the exposures that really differ.
    @Test func identicalPhysicalExposuresReduceTheValidatedProfile() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        var frames = try Self.writeScene(.full9, clientCaptureID: id)
        frames[0].exposureDurationSeconds = frames[1].exposureDurationSeconds
        frames[0].iso = frames[1].iso

        let audit = BracketAuditor.audit(frames: frames, plan: Self.plan(.full9), evidence: Self.evidence(9, requests: [9]))

        #expect(audit.realFrames == 9)
        #expect(audit.distinctExposureLevels == 8)
        #expect(audit.duplicateExposurePairs == ["-4/-3"])
        #expect(audit.validatedProfile == .standard7)
        #expect(!audit.isTruthful)
    }

    // MARK: - Pipeline

    // The pipeline writes a real, readable master next to untouched sources and recovers
    // highlight and shadow detail EV 0 had lost.
    @Test func realPipelineWritesAVerifiedMasterAndRecoversRange() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(.full9, clientCaptureID: id)
        let sourceChecksums = frames.map(\.checksum)
        var manifest = Self.manifest(frames: frames, clientCaptureID: id, profile: .full9)
        manifest.state = .localReady
        let captureID = UUID()

        let result = HDRProcessingService.process(manifest: manifest, captureID: captureID) { _ in }
        let record = try result.get()

        let url = try #require(CaptureBundleStore.url(clientCaptureID: id, fileName: record.fileName))
        let data = try Data(contentsOf: url)
        #expect(data.count == record.byteCount)
        #expect(CaptureBundleStore.checksum(data) == record.checksum)
        #expect(record.captureID == captureID)
        #expect(record.pipelineVersion == HDRProcessingService.pipelineVersion)
        #expect(record.pixelWidth == Self.width && record.pixelHeight == Self.height)
        #expect(record.sourceFrameCount == 9)
        #expect(HDRMasterStore.read(clientCaptureID: id)?.checksum == record.checksum)

        // Sources are never modified.
        for (frame, checksum) in zip(frames, sourceChecksums) {
            let bytes = try #require(CaptureBundleStore.loadData(frame))
            #expect(CaptureBundleStore.checksum(bytes) == checksum)
        }

        // EV 0 clips the bright half and crushes the dark end; the master recovers both.
        #expect(record.ev0HighlightClipPercent > 10)
        #expect(record.hdrHighlightClipPercent < record.ev0HighlightClipPercent * 0.6)
        #expect(record.hdrShadowClipPercent <= record.ev0ShadowClipPercent)
        #expect(record.dynamicRangeVerdict == "PASS")
    }

    // A bracket without darker and brighter evidence cannot make an HDR: source rejected.
    @Test func singleExposureIsRejectedAsHDRSource() throws {
        let id = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: id) }
        let frames = try Self.writeScene(.single, clientCaptureID: id)
        var manifest = Self.manifest(frames: frames, clientCaptureID: id, profile: .single)
        manifest.state = .localReady

        let result = HDRProcessingService.process(manifest: manifest, captureID: UUID()) { _ in }
        guard case .failure(let failure) = result else {
            Issue.record("A single exposure must never produce an HDR master")
            return
        }
        #expect(failure.kind == .sourceRejected)
        #expect(failure.code == "HDR_INSUFFICIENT_EXPOSURES")
        #expect(HDRMasterStore.read(clientCaptureID: id) == nil)
    }

    // MARK: - App flow

    // PREPARING → READY with a real file: the primary image switches to the master, the
    // original stays first and untouched, and no credit moves.
    @Test func captureReachesReadyOnlyWithARealMasterAndCostsNothing() async throws {
        let state = AppState()
        state.realHDREnabled = true
        let property = try #require(state.properties.first)
        let balance = state.wallet.total
        let transactions = state.transactions.count

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }
        let frames = try Self.writeScene(.full9, clientCaptureID: attempt.id)
        var manifest = Self.manifest(frames: frames, clientCaptureID: attempt.id, profile: .full9)
        manifest.propertyID = property.id
        manifest.state = .localReady
        try CaptureBundleStore.writeManifest(manifest)

        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living,
            frameCount: manifest.actualFrameCount,
            localFile: manifest.referenceFrame?.localPhotoFile,
            manifest: manifest
        )
        state.endCaptureSequence()

        // Openable at once, showing EV 0.
        #expect(capture.status == .preparing)
        #expect(capture.displayFile?.fileName == manifest.referenceFrame?.fileName)
        #expect(capture.hdrMaster == nil)

        var live = capture
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(100))
            live = try #require(state.captures.first { $0.id == capture.id })
            if live.status != .preparing { break }
        }

        #expect(live.status == .ready)
        #expect(live.hdrState == .generated)
        #expect(live.hdrSource == .real)
        let master = try #require(live.hdrMaster)
        #expect(live.displayFile?.fileName == master.fileName)
        #expect(live.assets.first?.type == .original)
        #expect(live.assets.contains { $0.type == .hdrMaster && $0.id == master.assetID })
        #expect(state.hdrJobs[capture.id]?.stage == .done)
        #expect(state.hdrJobs[capture.id]?.errorCode == nil)

        #expect(state.wallet.total == balance)
        #expect(state.transactions.count == transactions)
    }

    // A source that cannot make an HDR ends in "Precisa de nova captura", never endless PREPARING.
    @Test func rejectedSourceEndsInNeedsRecapture() async throws {
        let state = AppState()
        state.realHDREnabled = true
        let property = try #require(state.properties.first)

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }
        let frames = try Self.writeScene(.single, clientCaptureID: attempt.id)
        var manifest = Self.manifest(frames: frames, clientCaptureID: attempt.id, profile: .single)
        manifest.state = .localReady
        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .kitchen, frameCount: 1,
            localFile: manifest.referenceFrame?.localPhotoFile, manifest: manifest
        )
        state.endCaptureSequence()

        var live = capture
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            live = try #require(state.captures.first { $0.id == capture.id })
            if live.status != .preparing { break }
        }
        #expect(live.status == .needsRecapture)
        #expect(live.hdrState == .sourceRejected)
        #expect(live.hdrMaster == nil)
        #expect(!live.assets.contains { $0.type == .hdrMaster })
        #expect(state.hdrJobs[capture.id]?.errorCode == "HDR_INSUFFICIENT_EXPOSURES")
    }

    // The watchdog closes a job that runs too long: Erro, never endless PREPARING.
    @Test func watchdogEndsAStuckJob() async throws {
        let state = AppState()
        state.realHDREnabled = true
        state.hdrTimeoutSeconds = 0.001
        let property = try #require(state.properties.first)

        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }
        let frames = try Self.writeScene(.full9, clientCaptureID: attempt.id)
        var manifest = Self.manifest(frames: frames, clientCaptureID: attempt.id, profile: .full9)
        manifest.state = .localReady
        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living, frameCount: 9,
            localFile: manifest.referenceFrame?.localPhotoFile, manifest: manifest
        )
        state.endCaptureSequence()

        var live = capture
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            live = try #require(state.captures.first { $0.id == capture.id })
            if live.status != .preparing { break }
        }
        #expect(live.status == .error)
        #expect(live.hdrState == .failed)
        #expect(state.hdrJobs[capture.id]?.errorCode == "HDR_TIMEOUT")
        // The original is still there to show and retry from.
        #expect(live.displayFile?.fileName == manifest.referenceFrame?.fileName)
    }

    // MARK: - Fixtures

    private static let width = 320
    private static let height = 240

    private static func plan(_ profile: CaptureProfile) -> BracketPlan {
        BracketPlan(profile: profile, segments: [profile.exposureValues], reason: "")
    }

    private static func evidence(_ callbacks: Int, requests: [Int]) -> BracketAuditor.CallbackEvidence {
        BracketAuditor.CallbackEvidence(
            nativeRequests: requests.count,
            framesPerRequest: requests,
            callbacks: callbacks,
            callbackErrors: 0,
            indexCollisions: 0
        )
    }

    /// Renders one exposure of a synthetic high-dynamic-range room: a radiance ramp from deep
    /// shadow to a bright window (×64), with vertical texture so alignment has features.
    private static func exposure(ev: Double) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                let radiance = 0.004 * pow(64.0 / 0.004, t)
                for band in 0..<4 {
                    let texture = band % 2 == 0 ? 1.0 : 0.8
                    let value = min(1, radiance * texture * pow(2, ev))
                    let encoded = pow(value, 1 / 2.2)
                    UIColor(white: encoded, alpha: 1).setFill()
                    let bandHeight = CGFloat(height) / 4
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(band) * bandHeight, width: 1, height: bandHeight))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }

    private static func writeScene(_ profile: CaptureProfile, clientCaptureID: UUID) throws -> [CaptureFrame] {
        try profile.exposureValues.enumerated().map { index, ev in
            var frame = try CaptureBundleStore.writeFrame(
                photoData: exposure(ev: ev),
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

    private static func manifest(frames: [CaptureFrame], clientCaptureID: UUID, profile: CaptureProfile) -> CaptureManifest {
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
            captureProfile: profile,
            expectedFrameCount: profile.expectedFrameCount,
            actualFrameCount: frames.count,
            segmentCount: 1,
            orientation: .portrait,
            focusLockSucceeded: .succeeded,
            whiteBalanceLockSucceeded: .succeeded,
            state: .localValidating,
            startedAt: .now,
            completedAt: nil,
            frames: frames,
            requestedExposureValues: profile.exposureValues
        )
    }
}
