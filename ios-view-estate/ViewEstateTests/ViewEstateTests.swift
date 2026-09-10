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
}
