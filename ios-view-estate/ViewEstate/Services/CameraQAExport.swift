import Foundation

/// Per-frame exposure table (spec: Frame / Requested EV / Actual bias / ISO / Exposure time /
/// Highlight clipping / Shadow clipping), plus the timing and colour columns HDR will need.
enum CameraExposureTable {
    nonisolated static func csv(for manifest: CaptureManifest) -> String {
        var lines = [
            "frame,requested_ev,actual_bias,iso,exposure_time_s,highlight_clip_pct,shadow_clip_pct,"
                + "sensor_timestamp_s,interval_ms,lens_position,wb_temperature_k,wb_tint,bytes",
        ]
        let ordered = manifest.orderedFrames
        let intervals = manifest.frameIntervalsMs
        for (index, frame) in ordered.enumerated() {
            let analysis = CaptureBundleStore.url(for: frame).flatMap(FrameExposureAnalyzer.analyze(url:))
            let interval = index > 0 && index - 1 < intervals.count ? format(intervals[index - 1], "%.1f") : ""
            let fields: [String] = [
                "\(frame.sequenceIndex)",
                format(frame.requestedEV, "%.2f"),
                frame.actualExposureBias.map { format($0, "%.2f") } ?? "",
                frame.iso.map { format($0, "%.0f") } ?? "",
                frame.exposureDurationSeconds.map { format($0, "%.6f") } ?? "",
                analysis.map { format($0.highlightClippingPercent, "%.3f") } ?? "",
                analysis.map { format($0.shadowClippingPercent, "%.3f") } ?? "",
                frame.sensorTimestampSeconds.map { format($0, "%.4f") } ?? "",
                interval,
                frame.lensPosition.map { format($0, "%.4f") } ?? "",
                frame.whiteBalance?.temperature.map { format($0, "%.0f") } ?? "",
                frame.whiteBalance?.tint.map { format($0, "%.2f") } ?? "",
                "\(frame.byteCount)",
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func format(_ value: Double, _ pattern: String) -> String {
        String(format: pattern, value)
    }
}

/// Builds the structured development dataset from tagged physical captures:
///
/// ```
/// qa/camera/<device>/<scene>/<condition>_<id>/frame_*.jpg, manifest.json, exposure_table.csv
/// ```
///
/// Only captures explicitly tagged in the Camera Lab are included, so a customer photograph can
/// never end up in the dataset by accident. Nothing is uploaded anywhere: the archive is handed to
/// the developer through the system share sheet.
enum CameraQADatasetExporter {
    enum ExportError: Error {
        case nothingTagged
        case archiveFailed
    }

    nonisolated static func export(_ manifests: [CaptureManifest]) throws -> URL {
        let tagged = manifests.filter { $0.qaTag != nil && $0.state.isValid }
        guard !tagged.isEmpty else { throw ExportError.nothingTagged }

        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let staging = fileManager.temporaryDirectory.appendingPathComponent("ViewEstate-QA-\(stamp)", isDirectory: true)
        try? fileManager.removeItem(at: staging)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for manifest in tagged {
            guard let tag = manifest.qaTag else { continue }
            let folder = staging
                .appendingPathComponent("qa/camera", isDirectory: true)
                .appendingPathComponent(sanitize(manifest.device), isDirectory: true)
                .appendingPathComponent(tag.scene.folder, isDirectory: true)
                .appendingPathComponent("\(tag.condition.rawValue.lowercased())_\(manifest.clientCaptureID.uuidString.prefix(8))", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            for frame in manifest.orderedFrames {
                guard let source = CaptureBundleStore.url(for: frame) else { continue }
                try? fileManager.copyItem(at: source, to: folder.appendingPathComponent(frame.fileName))
            }
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try Data(CameraExposureTable.csv(for: manifest).utf8).write(to: folder.appendingPathComponent("exposure_table.csv"))
        }

        return try archive(staging, name: "ViewEstate-QA-\(stamp).zip")
    }

    /// Zips a folder with the system's own archiver (file coordination `.forUploading`).
    private nonisolated static func archive(_ folder: URL, name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        try? FileManager.default.removeItem(at: folder)
        guard coordinationError == nil, copyError == nil,
              FileManager.default.fileExists(atPath: destination.path)
        else { throw ExportError.archiveFailed }
        return destination
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Drafts the Final Camera Calibration Report from real data on this device.
///
/// Every PASS/FAIL is derived from measured captures and marked as automatic; anything without
/// evidence stays PENDING. The recommended status is a suggestion — a device only becomes
/// CALIBRATED when a person signs the physical QA off.
enum CameraCalibrationReportBuilder {
    struct Input: Sendable {
        var diagnostics: CameraDiagnostics
        var manifests: [CaptureManifest]
        var appVersion: String
    }

    enum Verdict: String {
        case pass = "PASS"
        case fail = "FAIL"
        case pending = "PENDING"
    }

    nonisolated static func build(_ input: Input) -> String {
        let manifests = input.manifests.filter { $0.captureSource == .nativeReal }
        let valid = manifests.filter(\.state.isValid)
        let diagnostics = input.diagnostics
        let calibration = diagnostics.calibration
        let capabilities = diagnostics.capabilities
        let latest = valid.first

        func tagged(_ scene: QAScene) -> [CaptureManifest] { valid.filter { $0.qaTag?.scene == scene } }
        func tagged(_ condition: QAHoldCondition) -> [CaptureManifest] { valid.filter { $0.qaTag?.condition == condition } }

        let durations = valid.compactMap { $0.quality?.bracketDurationMs }
        let averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)

        // Dynamic range verdicts from real histograms of the tagged scenes.
        let windowVerdict = dynamicRange(tagged(.livingRoomWindow)) { $0.darkestRecoversHighlights }
        let darkVerdict = dynamicRange(tagged(.darkBedroom)) { $0.brightestRecoversShadows }
        let mixed = tagged(.mixedLighting)
        let mixedVerdict: Verdict = mixed.isEmpty
            ? .pending
            : (mixed.contains { $0.quality?.whiteBalanceVariation == true } ? .fail
                : dynamicRange(mixed) { $0.darkestRecoversHighlights && $0.brightestRecoversShadows })

        let runs = diagnostics.sessionRuns
        let repeatedVerdict: Verdict = runs.count < 20
            ? .pending
            : (runs.suffix(20).allSatisfy(\.succeeded) && diagnostics.duplicateAttemptCount == 0 ? .pass : .fail)

        let offline = valid.filter { $0.quality?.capturedOffline == true }
        let offlineVerdict: Verdict = offline.count >= 3 ? .pass : .pending

        let interrupted = manifests.filter { $0.state == .interrupted }
        let recovered = interrupted.contains { failure in valid.contains { $0.startedAt > failure.startedAt } }
        let interruptionVerdict: Verdict = interrupted.isEmpty ? .pending : (recovered ? .pass : .fail)

        let sensorVerdict: Verdict = valid.isEmpty
            ? .pending
            : (valid.contains { $0.quality?.motion.sensorAvailable == true } ? .pass : .fail)

        let focusShifts = valid.filter { $0.quality?.focusShiftDetected == true }.count
        let focusTimeouts = valid.filter { $0.quality?.focusTimeout == true }.count
        let wbVariations = valid.filter { $0.quality?.whiteBalanceVariation == true }.count

        let verdicts = [windowVerdict, darkVerdict, mixedVerdict, repeatedVerdict, offlineVerdict, interruptionVerdict, sensorVerdict]
        let recommended: String
        if verdicts.contains(.fail) || focusShifts > 0 || wbVariations > 0 {
            recommended = "LIMITED (automatic draft — review required)"
        } else if verdicts.allSatisfy({ $0 == .pass }) {
            recommended = "CALIBRATED — candidate, requires human sign-off"
        } else {
            recommended = "TESTING — physical evidence incomplete"
        }

        var lines: [String] = []
        lines.append("VIEW ESTATE — CAMERA CALIBRATION REPORT (automatic draft)")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: .now))")
        lines.append("")
        lines.append("DEVICE")
        lines.append("Model: \(capabilities?.deviceModel ?? latest?.device ?? "—")")
        lines.append("iOS: \(capabilities?.systemVersion ?? latest?.iOSVersion ?? "—")")
        lines.append("App Build: \(input.appVersion)")
        lines.append("")
        lines.append("CAMERA")
        lines.append("Physical camera: \(latest?.quality?.lens?.cameraUniqueID ?? diagnostics.setup?.deviceID ?? "—")")
        lines.append("Lens: \(latest?.lensType ?? diagnostics.setup?.lens ?? "—")"
            + (latest?.quality?.lens?.focalLengthEquivalentMM.map { String(format: " · %.0f mm eq.", $0) } ?? ""))
        lines.append("Resolution: \(latest?.referenceFrame?.dimensionDescription ?? capabilities?.activeFormat ?? "—")")
        lines.append("")
        lines.append("CALIBRATION PROFILE")
        lines.append("Profile: \(calibration.versionLabel) · status \(calibration.status.devLabel) · lens \(calibration.preferredLens.devLabel)")
        lines.append("")
        lines.append("BRACKET")
        lines.append("Profile: \(latest?.captureProfile.devLabel ?? diagnostics.plan?.profile.devLabel ?? "—")"
            + " (\(latest?.quality?.ladderSource.devLabel ?? diagnostics.plan?.ladderSource.devLabel ?? "—"))")
        lines.append("Exposure values: \((latest?.requestedLadder ?? diagnostics.plan?.exposureValues ?? []).map { CaptureProfile.evLabel($0) }.joined(separator: " "))")
        lines.append("Average total bracket duration: \(averageDuration.map { String(format: "%.0f ms (n=%d)", $0, durations.count) } ?? "—")")
        lines.append("")
        lines.append("STABILITY (mean score · mean duration)")
        for condition in QAHoldCondition.allCases {
            lines.append("\(conditionLabel(condition)): \(summary(tagged(condition)))")
        }
        lines.append("")
        lines.append("FOCUS")
        lines.append("Lock supported: \(capabilities.map { $0.supportsFocusLock ? "YES" : "NO" } ?? "—")")
        lines.append("Result: \(valid.count - focusShifts)/\(valid.count) without focus shift · \(focusTimeouts) timeout(s)")
        lines.append("")
        lines.append("WHITE BALANCE")
        lines.append("Lock supported: \(capabilities.map { $0.supportsWhiteBalanceLock ? "YES" : "NO" } ?? "—")")
        lines.append("Result: \(valid.count - wbVariations)/\(valid.count) without variation")
        lines.append("")
        lines.append("LEVEL")
        lines.append("Real sensor: \(sensorVerdict.rawValue)")
        lines.append("")
        lines.append("DYNAMIC RANGE TEST")
        lines.append("Bright window: \(windowVerdict.rawValue) (n=\(tagged(.livingRoomWindow).count))")
        lines.append("Dark interior: \(darkVerdict.rawValue) (n=\(tagged(.darkBedroom).count))")
        lines.append("Mixed lighting: \(mixedVerdict.rawValue) (n=\(mixed.count))")
        lines.append("")
        lines.append("REPEATED CAPTURE")
        lines.append("20 brackets: \(repeatedVerdict.rawValue) (\(runs.count) this session, duplicates \(diagnostics.duplicateAttemptCount))")
        lines.append("")
        lines.append("OFFLINE")
        lines.append("Multiple brackets: \(offlineVerdict.rawValue) (\(offline.count) valid offline)")
        lines.append("")
        lines.append("INTERRUPTION RECOVERY")
        lines.append("\(interruptionVerdict.rawValue) (\(interrupted.count) interrupted, recovered: \(recovered ? "YES" : "NO"))")
        lines.append("")
        lines.append("KNOWN LIMITATIONS")
        var limitations: [String] = []
        if capabilities?.supportsBracketCapture == false { limitations.append("- Camera reports no bracket support.") }
        if capabilities?.supportsFocusLock == false { limitations.append("- No focus lock on this camera.") }
        if capabilities?.supportsWhiteBalanceLock == false { limitations.append("- No white balance lock on this camera.") }
        if focusShifts > 0 { limitations.append("- Focus shift detected in \(focusShifts) bracket(s).") }
        if wbVariations > 0 { limitations.append("- White balance variation in \(wbVariations) bracket(s).") }
        if valid.contains(where: { $0.quality?.motion.assessment == .severe }) {
            limitations.append("- Severe motion recorded in at least one bracket.")
        }
        lines.append(contentsOf: limitations.isEmpty ? ["- None measured yet."] : limitations)
        lines.append("")
        lines.append("RECOMMENDED STATUS")
        lines.append(recommended)
        return lines.joined(separator: "\n")
    }

    private nonisolated static func dynamicRange(
        _ manifests: [CaptureManifest],
        passes: (BracketDynamicRangeReport) -> Bool
    ) -> Verdict {
        guard !manifests.isEmpty else { return .pending }
        let reports = manifests.compactMap(evaluate)
        guard !reports.isEmpty else { return .pending }
        return reports.contains(where: passes) ? .pass : .fail
    }

    nonisolated static func evaluate(_ manifest: CaptureManifest) -> BracketDynamicRangeReport? {
        let entries = manifest.orderedFrames.compactMap { frame -> BracketDynamicRangeReport.Entry? in
            guard let url = CaptureBundleStore.url(for: frame),
                  let analysis = FrameExposureAnalyzer.analyze(url: url)
            else { return nil }
            return BracketDynamicRangeReport.Entry(requestedEV: frame.requestedEV, analysis: analysis)
        }
        return BracketDynamicRangeReport.evaluate(entries)
    }

    private nonisolated static func summary(_ manifests: [CaptureManifest]) -> String {
        guard !manifests.isEmpty else { return "PENDING (no tagged captures)" }
        let scores = manifests.compactMap { $0.quality?.stabilityScore }
        let durations = manifests.compactMap { $0.quality?.bracketDurationMs }
        let score = scores.isEmpty ? "—" : String(format: "%.2f", scores.reduce(0, +) / Double(scores.count))
        let duration = durations.isEmpty ? "—" : String(format: "%.0f ms", durations.reduce(0, +) / Double(durations.count))
        return "\(score) · \(duration) (n=\(manifests.count))"
    }

    private nonisolated static func conditionLabel(_ condition: QAHoldCondition) -> String {
        switch condition {
        case .tripod: "Tripod"
        case .handheld: "Handheld"
        case .intentionalMotion: "Intentional motion"
        }
    }
}
