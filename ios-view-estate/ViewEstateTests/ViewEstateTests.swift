//
//  ViewEstateTests.swift
//  ViewEstateTests
//

import Foundation
import Testing
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

    @Test func everyKeyExistsInBothDictionaries() {
        let missingInBR = Strings.ptPT.keys.filter { Strings.ptBR[$0] == nil }
        let missingInPT = Strings.ptBR.keys.filter { Strings.ptPT[$0] == nil }
        #expect(missingInBR.isEmpty)
        #expect(missingInPT.isEmpty)
    }
}
