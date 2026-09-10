import Foundation

/// Turns one finished shutter action into a validated, self-describing capture bundle.
///
/// The manifest is written before anything is considered complete, then validated atomically.
/// An attempt that fails validation is still recorded — as `CAPTURE_INCOMPLETE` or `INTERRUPTED`,
/// with its normalised failure code — so a partial bracket can never be mistaken for a valid one
/// and the evidence stays on the device for inspection.
enum CaptureManifestBuilder {
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// Writes and validates the bundle of a successful bracket.
    ///
    /// - Throws: `CameraError` — already normalised, safe to show as friendly copy.
    static func finalize(
        result: BracketCaptureResult,
        attempt: CaptureAttempt,
        property: Property,
        organizationID: String
    ) throws -> CaptureManifest {
        let startedAt = Date()
        var manifest = manifest(
            result: result,
            attempt: attempt,
            property: property,
            organizationID: organizationID,
            state: .localValidating
        )

        // The manifest lands on disk before validation, so an interrupted app still leaves a
        // complete, inspectable record of what happened.
        try CaptureBundleStore.writeManifest(manifest)

        if let failure = CaptureBundleValidator.validate(manifest) {
            manifest.state = failure.bundleState
            manifest.failureCode = failure.code
            manifest.completedAt = Date()
            try? CaptureBundleStore.writeManifest(manifest)
            VELog.cameraError(failure.code, "manifest \(manifest.frameCountDescription)")
            throw failure
        }

        manifest.state = .localReady
        manifest.completedAt = Date()
        manifest.manifestSeconds = Date().timeIntervalSince(startedAt)
        try CaptureBundleStore.writeManifest(manifest)
        VELog.camera(
            "manifest ready profile=\(manifest.captureProfile.devLabel) "
                + "frames=\(manifest.frameCountDescription) size=\(manifest.totalSizeDescription)"
        )
        return manifest
    }

    /// Records a bracket that did not complete. Never returns a usable capture.
    @discardableResult
    static func recordFailure(
        _ failure: BracketCaptureFailure,
        attempt: CaptureAttempt,
        property: Property,
        organizationID: String
    ) -> CaptureManifest {
        var manifest = manifest(
            result: failure.partial,
            attempt: attempt,
            property: property,
            organizationID: organizationID,
            state: failure.code.bundleState
        )
        manifest.failureCode = failure.code.code
        manifest.completedAt = Date()
        try? CaptureBundleStore.writeManifest(manifest)
        VELog.cameraError(
            failure.code.code,
            "incomplete \(manifest.frameCountDescription) profile=\(manifest.captureProfile.devLabel)"
        )
        return manifest
    }

    private static func manifest(
        result: BracketCaptureResult,
        attempt: CaptureAttempt,
        property: Property,
        organizationID: String,
        state: CaptureBundleState
    ) -> CaptureManifest {
        CaptureManifest(
            captureID: nil,
            clientCaptureID: attempt.id,
            organizationID: organizationID,
            propertyID: property.id,
            roomID: attempt.room.rawValue,
            device: result.deviceModel,
            iOSVersion: result.systemVersion,
            appVersion: appVersion,
            cameraID: result.cameraID,
            lensType: result.lensType,
            captureProfile: result.plan.profile,
            expectedFrameCount: result.plan.expectedFrameCount,
            actualFrameCount: result.frames.count,
            segmentCount: result.plan.segments.count,
            orientation: result.orientation,
            focusLockSucceeded: result.focusLock,
            whiteBalanceLockSucceeded: result.whiteBalanceLock,
            state: state,
            startedAt: result.startedAt,
            completedAt: nil,
            firstFrameSeconds: result.firstFrameSeconds,
            bracketSeconds: result.bracketSeconds,
            persistSeconds: result.persistSeconds,
            frames: result.frames.sorted { $0.sequenceIndex < $1.sequenceIndex }
        )
    }
}
