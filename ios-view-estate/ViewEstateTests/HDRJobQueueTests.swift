//
//  HDRJobQueueTests.swift
//  ViewEstateTests
//
//  HDR job lifecycle: app-level queue with concurrency 1, watchdog that always releases the
//  worker, idempotent restore, physical input check and property counts. Synthetic fixtures
//  only prove lifecycle behaviour, never image quality.
//

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ViewEstate

@MainActor
@Suite(.serialized)
struct HDRJobQueueTests {

    // MARK: - Queue

    /// A, B and C are processed one at a time, in order, and none stays preparing.
    @Test func threeCapturesRunSequentiallyAndAllFinish() async throws {
        let state = Self.makeState()
        let property = try #require(state.properties.first)
        var ids: [UUID] = []
        var clients: [UUID] = []
        defer { clients.forEach { CaptureBundleStore.delete(clientCaptureID: $0) } }

        for _ in 0..<3 {
            let (capture, client) = try Self.register(state, property: property)
            ids.append(capture.id)
            clients.append(client)
        }
        #expect(ids.allSatisfy { state.activeHDRJob(for: $0) != nil })
        #expect(ids.allSatisfy { state.activeHDRJob(for: $0)?.requestedPipeline == .v2 })

        var maxRunning = 0
        // Generous bound: the full suite runs other heavy HDR suites in parallel.
        for _ in 0..<4800 {
            maxRunning = max(maxRunning, state.hdrQueue.filter { $0.state.isRunning }.count)
            if ids.allSatisfy({ id in state.captures.first { $0.id == id }?.status != .preparing }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(maxRunning <= 1)
        let jobs = ids.compactMap { state.latestHDRJob(for: $0) }
        #expect(jobs.count == 3)
        for job in jobs {
            let capture = state.captures.first { $0.id == job.captureID }
            #expect(
                job.state == .ready || job.state == .failed,
                "state=\(job.state.rawValue) stage=\(job.stage.rawValue) code=\(job.errorCode ?? "-") capture=\(capture?.jobState.rawValue ?? "-")"
            )
            #expect(job.actualPipeline == .v2)
        }
        // Strictly sequential: each job starts after the previous one finished.
        for (previous, next) in zip(jobs, jobs.dropFirst()) {
            let finished = try #require(previous.finishedAt)
            let started = try #require(next.startedAt)
            #expect(started >= finished)
        }
        #expect(ids.allSatisfy { id in state.captures.first { $0.id == id }?.status != .preparing })
        // None of the three still holds the worker. (The worker itself may already be busy with
        // bundles another suite left on disk, which this state restored at launch.)
        #expect(ids.allSatisfy { state.activeHDRJob(for: $0) == nil })
    }

    /// A job past its time limit fails with V2_TIMEOUT, the original stays viewable and the
    /// worker is released so the next capture still gets processed.
    @Test func timeoutFailsTheJobAndReleasesTheWorker() async throws {
        let state = Self.makeState()
        state.hdrV2TimeoutSeconds = 0.001
        let property = try #require(state.properties.first)

        let (a, clientA) = try Self.register(state, property: property)
        defer { CaptureBundleStore.delete(clientCaptureID: clientA) }
        let liveA = try await Self.waitUntilDone(state, a.id)
        #expect(liveA.status == .error)
        #expect(liveA.hdrState == .failed)
        #expect(state.latestHDRJob(for: a.id)?.state == .failed)
        #expect(state.latestHDRJob(for: a.id)?.errorCode == HDRPipelineV2.Code.timeout)
        #expect(state.hdrJobs[a.id]?.errorCode == HDRPipelineV2.Code.timeout)
        #expect(liveA.displayFile?.fileName == liveA.manifest?.referenceFrame?.fileName)

        state.hdrV2TimeoutSeconds = 120
        let (b, clientB) = try Self.register(state, property: property)
        defer { CaptureBundleStore.delete(clientCaptureID: clientB) }
        let liveB = try await Self.waitUntilDone(state, b.id)
        #expect(liveB.status != .preparing)
        #expect(state.latestHDRJob(for: b.id)?.startedAt != nil)
        #expect(state.latestHDRJob(for: b.id)?.state != .running)
    }

    /// A shutter state that never ends can only delay processing for a bounded time.
    @Test func neverEndingShutterOnlyDefersForABoundedTime() async throws {
        let state = Self.makeState()
        state.hdrCaptureDeferSeconds = 0.3
        let property = try #require(state.properties.first)
        let (a, client) = try Self.register(state, property: property)
        defer { CaptureBundleStore.delete(clientCaptureID: client) }

        // A new shutter sequence opens and is never closed.
        _ = try #require(state.beginCaptureAttempt(property: property, room: .kitchen))
        defer { state.endCaptureSequence() }
        let live = try await Self.waitUntilDone(state, a.id)
        #expect(live.status != .preparing)
        #expect(state.latestHDRJob(for: a.id)?.startedAt != nil)
    }

    // MARK: - Restore

    @Test func restoreRecreatesMissingJobsOnceAndNeverDuplicates() async throws {
        let state = Self.makeState()
        let property = try #require(state.properties.first)

        // A real capture that ended up preparing with no HDR job at all.
        state.realHDREnabled = false
        state.preparationSeconds = 60
        let (orphan, client) = try Self.register(state, property: property)
        defer { CaptureBundleStore.delete(clientCaptureID: client) }
        #expect(state.latestHDRJob(for: orphan.id) == nil)
        state.realHDREnabled = true

        #expect(state.restorePendingHDRJobs() == 1)
        #expect(state.hdrMissingJobs[orphan.id] != nil)
        #expect(state.restorePendingHDRJobs() == 0)
        state.handleScenePhase(.active)
        #expect(state.hdrQueue.filter { $0.captureID == orphan.id }.count == 1)

        let live = try await Self.waitUntilDone(state, orphan.id)
        #expect(live.status != .preparing)
        #expect(live.hdrState != .mock)
        #expect(state.restorePendingHDRJobs() == 0)
    }

    // MARK: - Physical input check

    @Test func missingExposureFileNeedsRecaptureWithExactCode() async throws {
        let state = Self.makeState()
        let property = try #require(state.properties.first)
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        defer { CaptureBundleStore.delete(clientCaptureID: attempt.id) }
        let frames = try Self.writeScene(clientCaptureID: attempt.id)
        var manifest = Self.manifest(frames, attempt.id)
        manifest.propertyID = property.id
        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living, frameCount: 9,
            localFile: manifest.referenceFrame?.localPhotoFile, manifest: manifest
        )
        // A non-reference exposure disappears before the worker reaches the job.
        let lost = try #require(frames.first { !$0.isReferenceExposure })
        try FileManager.default.removeItem(at: try #require(CaptureBundleStore.url(for: lost)))
        state.endCaptureSequence()

        let live = try await Self.waitUntilDone(state, capture.id)
        #expect(live.status == .needsRecapture)
        #expect(live.hdrState == .sourceRejected)
        #expect(state.latestHDRJob(for: capture.id)?.errorCode == HDRInputCheck.filesMissing)
        let check = try #require(state.hdrInputChecks[capture.id])
        #expect(check.existing == 8)
        #expect(check.expected == 9)
        #expect(check.hasEV0)
    }

    @Test func inputCheckAcceptsACompleteBracket() throws {
        let client = UUID()
        defer { CaptureBundleStore.delete(clientCaptureID: client) }
        let frames = try Self.writeScene(clientCaptureID: client)
        let result = HDRInputCheck.verify(Self.manifest(frames, client))
        #expect(result.errorCode == nil)
        #expect(result.existing == 9 && result.readable == 9 && result.validHashes == 9)
        #expect(result.hasEV0)
    }

    // MARK: - Counts

    /// Fotografias counts captures (never exposures), whatever their state; Pronta counts READY only.
    @Test func propertyCountsCaptureNotFrames() throws {
        let state = Self.makeState()
        state.realHDREnabled = false
        state.preparationSeconds = 60
        var property = DevFixtures.sergioResidence()
        property.photoCount = 0
        state.properties.append(property)
        for _ in 0..<3 {
            let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
            state.registerCapture(attempt: attempt, property: property, room: .living, frameCount: 9)
            state.endCaptureSequence()
        }
        // As after a relaunch: the stored counter lost the captures, the count must not.
        if let index = state.properties.firstIndex(where: { $0.id == property.id }) {
            state.properties[index].photoCount = 0
        }
        #expect(state.photoCount(for: property) == 3)
        #expect(state.readyCount(for: property.id) == 0)
    }

    // MARK: - Fixtures

    private static let width = 400
    private static let height = 300

    private static func makeState() -> AppState {
        let state = AppState()
        state.realHDREnabled = true
        state.hdrPipeline = .v2
        state.hdrWatchdogInterval = 0.05
        return state
    }

    private static func register(_ state: AppState, property: Property) throws -> (CaptureItem, UUID) {
        let attempt = try #require(state.beginCaptureAttempt(property: property, room: .living))
        let frames = try writeScene(clientCaptureID: attempt.id)
        var manifest = manifest(frames, attempt.id)
        manifest.propertyID = property.id
        let capture = state.registerCapture(
            attempt: attempt, property: property, room: .living,
            frameCount: manifest.actualFrameCount,
            localFile: manifest.referenceFrame?.localPhotoFile,
            manifest: manifest
        )
        state.endCaptureSequence()
        return (capture, attempt.id)
    }

    private static func waitUntilDone(_ state: AppState, _ id: UUID) async throws -> CaptureItem {
        var live = try #require(state.captures.first { $0.id == id })
        for _ in 0..<2400 {
            try await Task.sleep(for: .milliseconds(50))
            live = try #require(state.captures.first { $0.id == id })
            if live.status != .preparing && state.activeHDRJob(for: id) == nil { break }
        }
        return live
    }

    private static func reflectance(_ cx: Int, _ cy: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: cx &* 73_856_093 ^ cy &* 19_349_663)
        h ^= h >> 13
        h = h &* 1_274_126_177
        h ^= h >> 16
        return 0.15 + 0.7 * Double(h % 1000) / 999
    }

    private static func radiance(_ u: Double, _ v: Double) -> Double {
        let r = reflectance(Int((u / 16).rounded(.down)), Int((v / 16).rounded(.down)))
        if u >= 250, u < 370, v >= 30, v < 150 {
            let mullion = Int(u - 250) % 40 < 3 || Int(v - 30) % 40 < 3
            return mullion ? 0.05 : 3.0 * (0.75 + 0.25 * r)
        }
        var value = 0.12 * r
        if u < 120, v > 190 { value *= 0.01 }
        return value
    }

    private static func exposure(ev: Double) -> Data {
        let w = width, h = height
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let gain = pow(2, ev)
        for y in 0..<h {
            for x in 0..<w {
                let encoded = UInt8(max(0, min(255, (pow(min(1, radiance(Double(x), Double(y)) * gain), 1 / 2.2) * 255).rounded())))
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

    private static func writeScene(clientCaptureID: UUID) throws -> [CaptureFrame] {
        try CaptureProfile.full9.exposureValues.enumerated().map { index, ev in
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
