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

    // Preparation moves A preparar → Pronta and derives an HDR master from the immutable original.
    @Test func preparationReachesReadyAndDerivesHDRMaster() async throws {
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
        #expect(prepared.assets.contains { $0.type == .hdrMaster })
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
        let image = UIGraphicsImageRenderer(size: size).image { context in
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
            (1.5, .basic3),
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
        #expect(frames.map { Int($0.requestedEV) } == CaptureProfile.full9.exposureValues)
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
        #expect(shuffled.orderedFrames.map { Int($0.requestedEV) } == CaptureProfile.compact5.exposureValues)
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
            let brightness = 0.5 + Double(ev) * 0.1
            var frame = try CaptureBundleStore.writeFrame(
                photoData: jpeg(brightness: brightness),
                clientCaptureID: clientCaptureID,
                sequenceIndex: index,
                requestedEV: Double(ev),
                orientation: .portrait,
                cameraID: "test-camera",
                lensType: "Rear Wide"
            )
            frame.actualExposureBias = Double(ev)
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
