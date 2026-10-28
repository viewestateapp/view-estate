import Foundation

extension CaptureFrame {
    /// Development evidence keys written into `metadata` at the moment a file is persisted.
    nonisolated enum MetadataKey {
        /// 1-based native `capturePhoto` request that delivered this file.
        static let requestNumber = "requestNumber"
        /// 1-based arrival position of the `didFinishProcessingPhoto` callback within its request.
        static let callbackOrdinal = "callbackOrdinal"
        /// Exposures asked of the native request.
        static let requestedPhotoCount = "requestedPhotoCount"
        /// `AVCapturePhoto.photoCount` (physical device only).
        static let nativePhotoCount = "photoCount"
        /// `AVCaptureResolvedPhotoSettings.expectedPhotoCount` (physical device only).
        static let nativeExpectedPhotoCount = "expectedPhotoCount"
    }

    var requestNumber: Int? { metadata[MetadataKey.requestNumber].flatMap(Int.init) }

    /// "photoCount / expectedPhotoCount", native when the device reported it, otherwise arrival order
    /// over the requested count (marked with `~`).
    var photoCountDescription: String {
        if let native = metadata[MetadataKey.nativePhotoCount],
           let expected = metadata[MetadataKey.nativeExpectedPhotoCount] {
            return "\(native) / \(expected)"
        }
        let ordinal = metadata[MetadataKey.callbackOrdinal] ?? "?"
        let requested = metadata[MetadataKey.requestedPhotoCount] ?? "?"
        return "~\(ordinal) / \(requested)"
    }

    var hashSuffix: String { "…" + String(checksum.suffix(10)) }
}

/// Proof — or disproof — that one FULL_9 shutter action produced nine real, distinct exposures.
///
/// Built only from the manifest's recorded callbacks and the files actually on disk. What the
/// photographer hears (two or three shutter sounds for two native bracket requests) is irrelevant.
nonisolated struct Full9TruthCheck: Sendable {
    enum Verdict: String, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
        /// The capture was not a FULL_9 request.
        case notApplicable = "N/A"
    }

    struct Request: Sendable, Hashable {
        var number: Int
        var expectedPhotoCount: Int?
        var callbacks: Int?
        var persistedFiles: Int
    }

    static let required = 9
    static let requiredNativeRequests = 2

    var requestedProfile: CaptureProfile
    var requestedExposures: Int
    var nativeRequests: Int?
    var requests: [Request]
    var totalCallbacks: Int?
    var filesPersisted: Int
    var uniqueHashes: Int
    var distinctExposureLevels: Int
    var ev0Count: Int
    var realFrames: Int
    var actualProfile: CaptureProfile
    var expectedPhotoCountSource: String?
    var verdict: Verdict
    /// Exactly what is missing, one line each. Empty on PASS.
    var failures: [String]

    /// - Parameter live: the audit re-measured from disk now; its file counts win over the
    ///   capture-time audit, so a file deleted since capture is not counted.
    init(manifest: CaptureManifest, live: BracketAudit?) {
        let recorded = manifest.audit
        let disk = live ?? recorded
        requestedProfile = manifest.captureProfile
        requestedExposures = recorded?.requestedExposures ?? manifest.requestedLadder.count
        nativeRequests = recorded?.nativeRequests
        totalCallbacks = recorded?.callbacks
        filesPersisted = disk?.persistedFiles ?? 0
        uniqueHashes = disk?.uniqueHashes ?? 0
        distinctExposureLevels = disk?.distinctExposureLevels ?? 0
        ev0Count = disk?.ev0Frames ?? 0
        realFrames = disk?.realFrames ?? 0
        actualProfile = recorded?.validatedProfile ?? CaptureProfile.family(frameCount: realFrames)
        expectedPhotoCountSource = recorded?.expectedPhotoCountSource

        let persistedByRequest = Dictionary(grouping: manifest.frames.compactMap(\.requestNumber), by: { $0 })
            .mapValues(\.count)
        let requestCount = max(
            recorded?.framesPerRequest.count ?? 0,
            recorded?.callbacksPerRequest?.count ?? 0,
            persistedByRequest.keys.max() ?? 0
        )
        requests = (0..<requestCount).map { index in
            Request(
                number: index + 1,
                expectedPhotoCount: recorded?.expectedPhotoCountPerRequest?[safe: index],
                callbacks: recorded?.callbacksPerRequest?[safe: index],
                persistedFiles: persistedByRequest[index + 1] ?? recorded?.framesPerRequest[safe: index] ?? 0
            )
        }

        guard manifest.captureProfile == .full9 else {
            verdict = .notApplicable
            failures = []
            return
        }

        var missing: [String] = []
        let need = Self.required
        if requestedExposures != need {
            missing.append("Requested exposures \(requestedExposures) ≠ 9")
        }
        if let nativeRequests {
            if nativeRequests != Self.requiredNativeRequests {
                missing.append("Native requests \(nativeRequests) ≠ 2")
            }
        } else {
            missing.append("Native requests not recorded (capture predates auditing)")
        }
        for request in requests {
            guard let expected = request.expectedPhotoCount, let callbacks = request.callbacks else {
                missing.append("Request \(request.number): per-request callbacks not recorded")
                continue
            }
            if callbacks < expected {
                missing.append("Request \(request.number): \(callbacks)/\(expected) callbacks — missing \(expected - callbacks)")
            }
            if request.persistedFiles < expected {
                missing.append("Request \(request.number): \(request.persistedFiles)/\(expected) files persisted")
            }
        }
        if let totalCallbacks {
            if totalCallbacks < need { missing.append("Callbacks \(totalCallbacks)/9 — missing \(need - totalCallbacks)") }
        } else {
            missing.append("Callbacks not recorded")
        }
        if filesPersisted < need { missing.append("Files persisted \(filesPersisted)/9") }
        if uniqueHashes < need { missing.append("Unique hashes \(uniqueHashes)/9") }
        if distinctExposureLevels < need { missing.append("Distinct exposure levels \(distinctExposureLevels)/9") }
        if ev0Count != 1 { missing.append("EV 0 frames \(ev0Count) ≠ 1") }
        if realFrames < need { missing.append("Real frames \(realFrames)/9") }

        // Which ladder positions never became a real file.
        let present = Set(manifest.frames.map(\.sequenceIndex))
        for (index, ev) in manifest.requestedLadder.enumerated() where !present.contains(index) {
            missing.append("Missing frame #\(index) · EV \(CaptureProfile.evLabel(ev))")
        }

        failures = missing
        verdict = missing.isEmpty ? .pass : .fail
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
