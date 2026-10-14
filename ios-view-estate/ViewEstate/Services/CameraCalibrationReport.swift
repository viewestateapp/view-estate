import Foundation

/// Builds the Final Camera Calibration Report (Phase D3-V) from physical-device evidence.
///
/// Rules:
/// - Only native captures taken after the validation session started count as evidence.
/// - A simulator never produces evidence: every verdict stays PENDING there.
/// - Missing evidence is PENDING — never inferred as PASS.
/// - Visual observations come from a person (manual checks); automatic measurements can fail an
///   item but cannot pass one that also needs human eyes.
/// - The calibration status is a human decision. CALIBRATED can only be chosen when every gate
///   item of the calibration rule is PASS.
enum CameraCalibrationReportBuilder {
    struct Input: Sendable {
        var diagnostics: CameraDiagnostics
        var manifests: [CaptureManifest]
        var appVersion: String
        var session: PhysicalValidationSession?
        var creditsNow: Int
        var creditTransactionsNow: Int
        var isSimulator: Bool
        var currentLaunchID: UUID
        /// Bundles marked valid that no longer pass the bundle validator (computed on the main actor).
        var invalidAcceptedIDs: Set<UUID>
    }

    struct GateItem: Sendable, Hashable, Identifiable {
        var id: String { name }
        var name: String
        var verdict: ValidationVerdict
    }

    struct Output: Sendable {
        var text: String
        var gate: [GateItem]
        var suggestion: CalibrationDecision
        var evidenceAllowed: Bool

        /// CALIBRATED may only be signed when the whole calibration rule is met.
        var calibratedAllowed: Bool { evidenceAllowed && gate.allSatisfy { $0.verdict == .pass } }
    }

    private struct Analysed {
        var manifest: CaptureManifest
        var entries: [BracketDynamicRangeReport.Entry]
        var range: BracketDynamicRangeReport?

        var luminanceSpread: Double? {
            let means = entries.map(\.analysis.meanLuminance)
            guard let low = means.min(), let high = means.max(), entries.count >= 2 else { return nil }
            return high - low
        }
    }

    /// Darkest → brightest mean-luminance spread below this means the frames barely differ.
    nonisolated static let materialSpread = 0.15
    nonisolated static let storageFailure = "INSUFFICIENT_STORAGE"
    nonisolated static let interruptedFailure = "CAPTURE_INTERRUPTED"

    // MARK: - Build

    nonisolated static func build(_ input: Input) -> Output {
        let session = input.session
        let evidenceAllowed = session != nil && !input.isSimulator && session?.isSimulator == false
        let since = session?.startedAt ?? .distantFuture
        let manifests = evidenceAllowed
            ? input.manifests.filter { $0.captureSource == .nativeReal && $0.startedAt >= since }
            : []
        let valid = manifests.filter(\.state.isValid)
        let analysed = valid.map { manifest -> Analysed in
            let entries = entries(for: manifest)
            return Analysed(manifest: manifest, entries: entries, range: BracketDynamicRangeReport.evaluate(entries))
        }
        let runs = evidenceAllowed ? (session?.runs ?? []) : []
        let events = evidenceAllowed ? (session?.events ?? []) : []
        let byID = Dictionary(input.manifests.map { ($0.clientCaptureID, $0) }, uniquingKeysWith: { first, _ in first })

        func manual(_ check: ManualValidationCheck) -> ValidationVerdict {
            evidenceAllowed ? (session?.verdict(check) ?? .pending) : .pending
        }
        func scene(_ scene: QAScene) -> [Analysed] { analysed.filter { $0.manifest.qaTag?.scene == scene } }
        func held(_ condition: QAHoldCondition) -> [CaptureManifest] {
            valid.filter { $0.qaTag?.condition == condition }
        }

        let diagnostics = input.diagnostics
        let calibration = diagnostics.calibration
        let capabilities = diagnostics.capabilities
        let latest = valid.first

        // MARK: Exposure (section 13)
        let multiFrame = analysed.filter { $0.entries.count >= 2 }
        let materiallyDifferent = multiFrame.filter { ($0.luminanceSpread ?? 0) >= materialSpread }
        let missingReference = valid.filter { !$0.requestedLadder.contains { abs($0) < 0.001 } }
        let exposureVerdict: ValidationVerdict
        if analysed.isEmpty {
            exposureVerdict = .pending
        } else if multiFrame.isEmpty || !missingReference.isEmpty || materiallyDifferent.count < multiFrame.count {
            exposureVerdict = .fail
        } else {
            exposureVerdict = .pass
        }
        let biasErrors = valid.flatMap(\.frames).compactMap { frame in
            frame.actualExposureBias.map { abs($0 - frame.requestedEV) }
        }

        // MARK: Stability (section 17)
        let tripod = held(.tripod)
        let handheld = held(.handheld)
        let movement = held(.intentionalMotion)
        let tripodMean = meanScore(tripod)
        let movementMean = meanScore(movement)
        let tripodVerdict: ValidationVerdict = tripod.isEmpty
            ? .pending
            : (ratio(tripod) { $0.quality?.motion.assessment == MotionAssessment.none } >= 0.8 ? .pass : .fail)
        let handheldVerdict: ValidationVerdict = handheld.isEmpty
            ? .pending
            : (ratio(handheld) { isSensorBacked($0) && $0.quality?.motion.assessment != .severe } >= 0.8 ? .pass : .fail)
        let movementVerdict: ValidationVerdict
        if movement.isEmpty || tripod.isEmpty {
            movementVerdict = .pending
        } else {
            let detected = ratio(movement) { manifest in
                let assessment = manifest.quality?.motion.assessment
                return assessment == .warning || assessment == .severe
            }
            let separated = (movementMean ?? 1) < (tripodMean ?? 0)
            movementVerdict = detected >= 0.5 && separated ? .pass : .fail
        }
        let stabilityVerdict = ValidationVerdict.all([tripodVerdict, handheldVerdict, movementVerdict])

        // MARK: Level (section 18)
        let levelAuto: ValidationVerdict = valid.isEmpty
            ? .pending
            : (valid.contains { isSensorBacked($0) && $0.quality?.rollAngle != nil } ? .pass : .fail)
        let levelVerdict = ValidationVerdict.all([
            levelAuto, manual(.levelFollowsTilt), manual(.levelWarnsOutsideTolerance), manual(.sourceNotRotated),
        ])

        // MARK: Focus (section 15)
        let focusCapability = capabilityVerdict(capabilities?.supportsFocusLock, hasEvidence: !valid.isEmpty)
        let focusShifts = valid.filter { $0.quality?.focusShiftDetected == true }.count
        let focusLocked = valid.filter { $0.quality?.focusLockSucceeded == true }.count
        let focusTimeouts = valid.filter { $0.quality?.focusTimeout == true }.count
        let focusAuto: ValidationVerdict = valid.isEmpty ? .pending : (focusShifts == 0 ? .pass : .fail)
        let focusVerdict = ValidationVerdict.all([focusCapability, focusAuto, manual(.noVisibleRefocus)])

        // MARK: White balance (section 16)
        let wbCapability = capabilityVerdict(capabilities?.supportsWhiteBalanceLock, hasEvidence: !valid.isEmpty)
        let wbLocked = valid.filter { $0.quality?.whiteBalanceLockSucceeded == true }.count
        let wbVariations = valid.filter { $0.quality?.whiteBalanceVariation == true }
        let wbVerdict = ValidationVerdict.all([wbCapability, manual(.noWhiteBalanceJump)])

        // MARK: Lens & orientation
        let mixedLens = valid.filter { Set($0.frames.map(\.lensType)).count > 1 }
        let lensAuto: ValidationVerdict = valid.isEmpty ? .pending : (mixedLens.isEmpty ? .pass : .fail)
        let lensVerdict = ValidationVerdict.all([lensAuto, manual(.sameLensAllFrames)])
        let orientationVerdict = manual(.orientationConsistent)

        // MARK: Dynamic range (sections 5–12, 14)
        let sceneA = scene(.livingRoomWindow)
        let windowAuto = rangeVerdict(sceneA) { $0.darkestRecoversHighlights }
        let windowVerdict = ValidationVerdict.all([
            windowAuto,
            manual(.windowDetailInDarkestFrame),
            manual(.referenceExposureValid),
            manual(.interiorShadowsInBrightestFrame),
        ])
        let darkVerdict = rangeVerdict(scene(.darkBedroom)) { $0.brightestRecoversShadows }
        let sceneD = scene(.mixedLighting)
        let mixedRange = rangeVerdict(sceneD) { $0.darkestRecoversHighlights && $0.brightestRecoversShadows }
        let mixedWBVariations = sceneD.filter { $0.manifest.quality?.whiteBalanceVariation == true }.count
        let mixedWB: ValidationVerdict = sceneD.isEmpty ? .pending : (mixedWBVariations < sceneD.count ? .pass : .fail)
        let mixedVerdict = ValidationVerdict.all([mixedRange, mixedWB])

        // MARK: Timing (section 29)
        let succeededRuns = runs.filter(\.succeeded)
        let durations = succeededRuns.compactMap(\.bracketDurationMs)
        let intervals = valid.flatMap { $0.quality?.frameIntervalsMs ?? [] }

        // MARK: 20-bracket stress (section 20)
        let stressRuns = runs.filter { $0.failureCode != storageFailure }
        let stressFailures = stressRuns.filter { !$0.succeeded }
        let hasCleanTwenty = hasConsecutive(stressRuns, length: 20)
        let duplicateIDs = session.map { evidenceAllowed ? $0.duplicateClientCaptureIDs : 0 } ?? 0
        let manifestDuplicates = manifests.count - Set(manifests.map(\.clientCaptureID)).count
        let invalidAccepted = valid.filter { input.invalidAcceptedIDs.contains($0.clientCaptureID) }.count
        let stressVerdict: ValidationVerdict
        if stressRuns.count < 20 {
            stressVerdict = .pending
        } else {
            stressVerdict = hasCleanTwenty && duplicateIDs == 0 && manifestDuplicates == 0 && invalidAccepted == 0
                ? .pass : .fail
        }

        // MARK: Rapid repeat / duplicates (section 21)
        let rapidBurst = hasRapidBurst(succeededRuns)
        let duplicateVerdict: ValidationVerdict
        if duplicateIDs > 0 || manifestDuplicates > 0 {
            duplicateVerdict = .fail
        } else {
            duplicateVerdict = rapidBurst ? .pass : .pending
        }

        // MARK: Offline & restart (section 22)
        let offlineRuns = succeededRuns.filter(\.capturedOffline)
        let offlineSurviving = offlineRuns.filter { byID[$0.clientCaptureID]?.state.isValid == true }
        let offlineAuto: ValidationVerdict = offlineRuns.count < 5
            ? .pending
            : (offlineSurviving.count == offlineRuns.count ? .pass : .fail)
        let offlineVerdict = ValidationVerdict.all([offlineAuto, manual(.syncResumesSafely)])

        let restartRuns = offlineRuns.filter { $0.launchID != input.currentLaunchID }
        let restartAuto: ValidationVerdict = restartRuns.isEmpty
            ? .pending
            : (restartRuns.allSatisfy { byID[$0.clientCaptureID]?.state.isValid == true } ? .pass : .fail)
        let restartVerdict = ValidationVerdict.all([restartAuto, manual(.offlineCapturesVisibleAfterRestart)])

        // MARK: Interruptions (section 23)
        let interruptions = events.filter { $0.kind == .interrupted || $0.kind == .runtimeError }.count
        let recoveries = events.filter { $0.kind == .recovered }.count
        let recoveryFailures = events.filter { $0.kind == .recoveryFailed }.count
        let interruptedMarkedValid = runs.filter {
            $0.failureCode == interruptedFailure && byID[$0.clientCaptureID]?.state.isValid == true
        }.count
        var interruptionChecks = [manual(.backgroundForegroundRecovers), manual(.lockUnlockRecovers)]
        if manual(.callInterruptionRecovers) != .pending { interruptionChecks.append(manual(.callInterruptionRecovers)) }
        if recoveryFailures > 0 || interruptedMarkedValid > 0 { interruptionChecks.append(.fail) }
        let interruptionVerdict = ValidationVerdict.all(interruptionChecks)

        // MARK: Low storage (section 24)
        let storageBlocked = runs.filter { $0.failureCode == storageFailure }
        let storageLeak = storageBlocked.contains { byID[$0.clientCaptureID]?.state.isValid == true }
        let storageAuto: ValidationVerdict = storageBlocked.isEmpty ? .pending : (storageLeak ? .fail : .pass)
        let storageVerdict = ValidationVerdict.all([storageAuto, manual(.lowStorageShowsFriendlyMessage)])

        // MARK: Credits (section 31)
        let creditsVerdict: ValidationVerdict
        if let session, evidenceAllowed {
            creditsVerdict = session.creditsBefore == input.creditsNow
                && session.creditTransactionsBefore == input.creditTransactionsNow ? .pass : .fail
        } else {
            creditsVerdict = .pending
        }

        // MARK: Gate (section 33)
        let gate: [GateItem] = [
            GateItem(name: "Real multi-exposure bracket works reliably", verdict: .all([exposureVerdict, stressVerdict])),
            GateItem(name: "Dynamic range is useful", verdict: .all([windowVerdict, darkVerdict])),
            GateItem(name: "Focus is stable", verdict: focusVerdict),
            GateItem(name: "White balance is acceptably stable", verdict: wbVerdict),
            GateItem(name: "Same lens is preserved", verdict: lensVerdict),
            GateItem(name: "Orientation is correct", verdict: orientationVerdict),
            GateItem(name: "Sensor stability works", verdict: stabilityVerdict),
            GateItem(name: "Level works", verdict: levelVerdict),
            GateItem(name: "Offline capture works", verdict: offlineVerdict),
            GateItem(name: "Restart recovery works", verdict: restartVerdict),
            GateItem(name: "Repeated capture works", verdict: duplicateVerdict),
            GateItem(name: "Interruptions recover", verdict: interruptionVerdict),
            GateItem(name: "No critical camera crash", verdict: manual(.noCameraCrash)),
            GateItem(name: "CreditWallet unchanged", verdict: creditsVerdict),
        ]
        let suggestion: CalibrationDecision
        if !evidenceAllowed {
            suggestion = .pending
        } else if gate.allSatisfy({ $0.verdict == .pass }) {
            suggestion = .calibrated
        } else if exposureVerdict == .fail || stressVerdict == .fail || manual(.noCameraCrash) == .fail {
            suggestion = .unsupported
        } else if gate.contains(where: { $0.verdict == .fail }) {
            suggestion = .limited
        } else {
            suggestion = .pending
        }

        // MARK: Text
        var lines: [String] = []
        func add(_ line: String = "") { lines.append(line) }
        func pair(_ label: String, _ verdict: ValidationVerdict, _ detail: String = "") {
            add("\(label): \(verdict.rawValue)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        add("VIEW ESTATE — CAMERA CALIBRATION REPORT · PHASE D3-V")
        add("Generated: \(ISO8601DateFormatter().string(from: .now))")
        if input.isSimulator || session?.isSimulator == true {
            add("⚠ SIMULATOR — nothing here is physical evidence. Every verdict is PENDING.")
        } else if let session {
            add("Validation session: \(session.id.uuidString.prefix(8)) · started \(ISO8601DateFormatter().string(from: session.startedAt)) · \(session.launchCount) app launch(es)")
        } else {
            add("⚠ No validation session started. Camera Lab → Physical validation → Start. Every verdict is PENDING.")
        }
        add()

        add("DEVICE")
        add("Model: \(capabilities?.deviceModel ?? latest?.device ?? session?.deviceModel ?? "—")")
        add("iOS: \(capabilities?.systemVersion ?? latest?.iOSVersion ?? session?.systemVersion ?? "—")")
        add("Build: \(input.appVersion)")
        add()

        add("CAMERA")
        add("Physical camera: \(latest?.quality?.lens?.cameraUniqueID ?? diagnostics.setup?.deviceID ?? "—")")
        add("Physical lens: \(latest?.lensType ?? diagnostics.setup?.lens ?? "—")"
            + (latest?.quality?.lens?.focalLengthEquivalentMM.map { String(format: " · %.0f mm eq.", $0) } ?? ""))
        add("Resolution: \(latest?.referenceFrame?.dimensionDescription ?? capabilities?.activeFormat ?? "—")")
        add()

        add("CAPABILITIES")
        add("Min EV: \(capabilities.map { String(format: "%.2f", $0.minExposureBias) } ?? "—")")
        add("Max EV: \(capabilities.map { String(format: "%+.2f", $0.maxExposureBias) } ?? "—")")
        add("Max bracket count: \(capabilities.map { "\($0.maxBracketCount)" } ?? "—")")
        add("Focus lock: \(capabilities.map { $0.supportsFocusLock ? "YES" : "NO" } ?? "—") · WB lock: \(capabilities.map { $0.supportsWhiteBalanceLock ? "YES" : "NO" } ?? "—")")
        add("Calibration profile: \(calibration.versionLabel) · status \(calibration.status.devLabel)")
        add()

        let profileCounts = Dictionary(grouping: valid, by: \.captureProfile.devLabel).mapValues(\.count)
        add("PROFILE TESTED: \(profileCounts.isEmpty ? "PENDING" : profileCounts.sorted { $0.key < $1.key }.map { "\($0.key) (n=\($0.value))" }.joined(separator: ", "))")
        let recommended = session?.recommendedProfile.map { profile in
            profile == "CUSTOM" && !(session?.customLadder.isEmpty ?? true) ? "CUSTOM [\(session?.customLadder ?? "")]" : profile
        }
        add("PROFILE RECOMMENDED: \(evidenceAllowed ? (recommended ?? "PENDING (human decision)") : "PENDING")")
        add("EXPOSURE LADDER: \((latest?.requestedLadder ?? diagnostics.plan?.exposureValues ?? []).map { CaptureProfile.evLabel($0) }.joined(separator: " ").nonEmpty ?? "—")")
        add()

        add("EXPOSURE VALIDATION")
        pair("Frames genuinely different", exposureVerdict,
             analysed.isEmpty ? "" : "\(materiallyDifferent.count)/\(multiFrame.count) brackets with darkest→brightest luminance spread ≥ \(Int(materialSpread * 100))%")
        add("EV 0 present: \(valid.isEmpty ? "PENDING" : (missingReference.isEmpty ? "YES in every bracket" : "MISSING in \(missingReference.count)"))")
        add("Actual bias vs requested: \(biasErrors.isEmpty ? "—" : String(format: "max error %.2f EV, mean %.2f EV", biasErrors.max() ?? 0, mean(biasErrors) ?? 0))")
        add()

        add("STABILITY")
        pair("Tripod", tripodVerdict, scoreDetail(tripod))
        pair("Handheld", handheldVerdict, scoreDetail(handheld))
        pair("Intentional movement detection", movementVerdict, scoreDetail(movement))
        add()

        add("LEVEL")
        pair("Level", levelVerdict, "sensor \(levelAuto.rawValue) · follows tilt \(manual(.levelFollowsTilt).rawValue) · warns \(manual(.levelWarnsOutsideTolerance).rawValue) · source unrotated \(manual(.sourceNotRotated).rawValue) · tolerance ±\(String(format: "%.1f", calibration.levelToleranceDegrees))°")
        add()

        add("FOCUS")
        pair("Lock supported", focusCapability)
        pair("Bracket focus", focusVerdict, "lock \(focusLocked)/\(valid.count) · shifts \(focusShifts) · timeouts \(focusTimeouts) · visual \(manual(.noVisibleRefocus).rawValue) · \(calibration.focusStrategy.devLabel)")
        add()

        add("WHITE BALANCE")
        pair("Lock supported", wbCapability)
        pair("Bracket white balance", wbVerdict, "lock \(wbLocked)/\(valid.count) · WHITE_BALANCE_VARIATION in \(wbVariations.count) · visual \(manual(.noWhiteBalanceJump).rawValue)")
        if !wbVariations.isEmpty {
            add("  Variation in: " + wbVariations.prefix(8).map { "\($0.qaTag?.scene.rawValue ?? "?")/\($0.clientCaptureID.uuidString.prefix(8))" }.joined(separator: ", "))
        }
        add()

        add("LENS & ORIENTATION")
        pair("Same lens", lensVerdict, mixedLens.isEmpty ? "" : "mixed camera in \(mixedLens.count) bracket(s)")
        pair("Orientation", orientationVerdict)
        add()

        add("DYNAMIC RANGE")
        pair("Bright window", windowVerdict, windowDetail(sceneA, auto: windowAuto, manual: manual))
        pair("Dark interior", darkVerdict, "n=\(scene(.darkBedroom).count)")
        pair("Mixed light", mixedVerdict, "n=\(sceneD.count) · WB variation in \(mixedWBVariations)")
        for extra in [QAScene.whiteKitchen, .smallBathroom, .longCorridor, .exteriorDaylight, .exteriorSunset] {
            let items = scene(extra)
            let verdicts = items.compactMap(\.range?.verdict)
            add("\(extra.rawValue) · \(extra.title): \(items.isEmpty ? "PENDING" : "n=\(items.count) · " + Dictionary(grouping: verdicts, by: { $0 }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))")
        }
        add()

        add("REDUNDANT FRAME ANALYSIS")
        lines.append(contentsOf: redundancyLines(analysed))
        add()

        add("BRACKET")
        add("Average duration: \(ms(mean(durations)))")
        add("Fastest: \(ms(durations.min()))")
        add("Slowest: \(ms(durations.max()))")
        add("Tap → first frame: \(ms(mean(succeededRuns.compactMap(\.tapToFirstFrameMs))))")
        add("Frame-to-frame interval: mean \(ms(mean(intervals))) · max \(ms(intervals.max()))")
        add("Local persistence: frames \(ms(mean(succeededRuns.compactMap(\.framePersistMs)))) · validate + manifest \(ms(mean(succeededRuns.compactMap(\.finalizeMs))))")
        add()

        add("20-BRACKET STRESS TEST")
        add("Successful: \(stressRuns.count - stressFailures.count)")
        add("Failed: \(stressFailures.count)\(stressFailures.isEmpty ? "" : " (" + Dictionary(grouping: stressFailures, by: { $0.failureCode ?? "?" }).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: ", ") + ")")")
        pair("Result", stressVerdict, "clean run of 20: \(hasCleanTwenty ? "YES" : "NO") · duplicate IDs \(duplicateIDs) · invalid accepted \(invalidAccepted)")
        add()

        add("OFFLINE")
        pair("Offline", offlineVerdict, "\(offlineSurviving.count)/\(offlineRuns.count) offline brackets valid (min 5) · sync resumes \(manual(.syncResumesSafely).rawValue)")
        add()
        add("APP RESTART RECOVERY")
        pair("Restart", restartVerdict, "\(restartRuns.count) offline bracket(s) from an earlier launch checked · visible after relaunch \(manual(.offlineCapturesVisibleAfterRestart).rawValue)")
        add()
        add("INTERRUPTION RECOVERY")
        pair("Interruptions", interruptionVerdict, "session interruptions \(interruptions) · recovered \(recoveries) · recovery failed \(recoveryFailures) · interrupted marked valid \(interruptedMarkedValid) · background \(manual(.backgroundForegroundRecovers).rawValue) · lock \(manual(.lockUnlockRecovers).rawValue) · call \(manual(.callInterruptionRecovers).rawValue)")
        add()
        add("LOW STORAGE")
        pair("Low storage", storageVerdict, "\(storageBlocked.count) bracket(s) refused · partial valid captures \(storageLeak ? "YES" : "0")")
        add()
        add("DUPLICATE CAPTURE TEST")
        pair("Duplicates", duplicateVerdict, "rapid 3-tap burst \(rapidBurst ? "observed" : "not yet") · duplicate clientCaptureIDs \(duplicateIDs) · duplicate bundles \(manifestDuplicates)")
        add()

        add("CREDITS")
        add("Before: \(session.map { "\($0.creditsBefore) (\($0.creditTransactionsBefore) transactions)" } ?? "—")")
        add("After: \(input.creditsNow) (\(input.creditTransactionsNow) transactions)")
        add("Expected: UNCHANGED → \(creditsVerdict == .pass ? "UNCHANGED" : creditsVerdict == .fail ? "CHANGED" : "PENDING")")
        add("Note: the wallet is still a mock that resets on relaunch; compare within one launch.")
        add()

        add("STORAGE")
        lines.append(contentsOf: storageLines(valid))
        add()

        add("THERMAL / MEMORY")
        lines.append(contentsOf: healthLines(runs))
        add()

        add("ULTRA-WIDE (classified separately, never default)")
        let ultra = valid.filter { $0.quality?.lens?.lens == .ultraWide }
        add("Classification: \(evidenceAllowed ? (session?.ultraWide.rawValue ?? "PENDING") : "PENDING")")
        add("Brackets: \(ultra.count) · focus shifts \(ultra.filter { $0.quality?.focusShiftDetected == true }.count) · WB variation \(ultra.filter { $0.quality?.whiteBalanceVariation == true }.count)")
        if let notes = session?.ultraWideNotes, !notes.isEmpty, evidenceAllowed { add("Notes: \(notes)") }
        add()

        add("KNOWN LIMITATIONS")
        var limitations: [String] = []
        if capabilities?.supportsBracketCapture == false { limitations.append("- Camera reports no bracket support.") }
        if capabilities?.supportsFocusLock == false { limitations.append("- No focus lock on this camera.") }
        if capabilities?.supportsWhiteBalanceLock == false { limitations.append("- No white balance lock on this camera.") }
        if focusShifts > 0 { limitations.append("- Focus shift detected in \(focusShifts) bracket(s).") }
        if !wbVariations.isEmpty { limitations.append("- White balance variation in \(wbVariations.count) bracket(s).") }
        if valid.contains(where: { $0.quality?.motion.assessment == .severe }) {
            limitations.append("- Severe motion recorded in at least one bracket (frames preserved).")
        }
        if let notes = session?.notes, !notes.isEmpty, evidenceAllowed { limitations.append("- Tester notes: \(notes)") }
        lines.append(contentsOf: limitations.isEmpty ? ["- None measured yet."] : limitations)
        add()

        add("CALIBRATION GATE (section 33)")
        for item in gate { add("[\(item.verdict.rawValue)] \(item.name)") }
        add()

        add("CALIBRATION STATUS")
        let decision = evidenceAllowed ? (session?.decision ?? .pending) : .pending
        var status = decision.rawValue
        if decision == .calibrated, !gate.allSatisfy({ $0.verdict == .pass }) {
            status += " — ⚠ gate no longer met, review required"
        }
        if decision != .pending, let session, !session.signedOffBy.isEmpty {
            status += " · signed off by \(session.signedOffBy)"
                + (session.signedOffAt.map { " on \(ISO8601DateFormatter().string(from: $0))" } ?? "")
        }
        add(status)
        add("Automatic suggestion: \(suggestion.rawValue) (never applied automatically)")

        return Output(text: lines.joined(separator: "\n"), gate: gate, suggestion: suggestion, evidenceAllowed: evidenceAllowed)
    }

    // MARK: - Analysis helpers

    nonisolated static func evaluate(_ manifest: CaptureManifest) -> BracketDynamicRangeReport? {
        BracketDynamicRangeReport.evaluate(entries(for: manifest))
    }

    private nonisolated static func entries(for manifest: CaptureManifest) -> [BracketDynamicRangeReport.Entry] {
        manifest.orderedFrames.compactMap { frame in
            guard let url = CaptureBundleStore.url(for: frame),
                  let analysis = FrameExposureAnalyzer.analyze(url: url)
            else { return nil }
            return BracketDynamicRangeReport.Entry(requestedEV: frame.requestedEV, analysis: analysis)
        }
    }

    private nonisolated static func rangeVerdict(
        _ items: [Analysed],
        passes: (BracketDynamicRangeReport) -> Bool
    ) -> ValidationVerdict {
        let reports = items.compactMap(\.range)
        guard !reports.isEmpty else { return .pending }
        return reports.contains(where: passes) ? .pass : .fail
    }

    private nonisolated static func capabilityVerdict(_ supported: Bool?, hasEvidence: Bool) -> ValidationVerdict {
        guard let supported, hasEvidence else { return .pending }
        return supported ? .pass : .fail
    }

    private nonisolated static func isSensorBacked(_ manifest: CaptureManifest) -> Bool {
        manifest.quality?.motion.sensorAvailable == true
    }

    private nonisolated static func ratio(_ items: [CaptureManifest], _ predicate: (CaptureManifest) -> Bool) -> Double {
        guard !items.isEmpty else { return 0 }
        return Double(items.filter(predicate).count) / Double(items.count)
    }

    private nonisolated static func meanScore(_ items: [CaptureManifest]) -> Double? {
        mean(items.compactMap { $0.quality?.stabilityScore })
    }

    private nonisolated static func scoreDetail(_ items: [CaptureManifest]) -> String {
        guard !items.isEmpty else { return "no tagged brackets" }
        let warnings = items.filter { $0.quality?.motion.assessment == .warning }.count
        let severe = items.filter { $0.quality?.motion.assessment == .severe }.count
        let peak = items.compactMap { $0.quality?.motion.maxRotationDuringCapture }.max()
        return "n=\(items.count) · mean score \(meanScore(items).map { String(format: "%.2f", $0) } ?? "—")"
            + " · warnings \(warnings) · severe \(severe)"
            + (peak.map { String(format: " · peak %.2f rad/s", $0) } ?? "")
    }

    private nonisolated static func windowDetail(
        _ items: [Analysed],
        auto: ValidationVerdict,
        manual: (ManualValidationCheck) -> ValidationVerdict
    ) -> String {
        let darkestClip = items.compactMap { $0.entries.min { $0.requestedEV < $1.requestedEV }?.analysis.highlightClippingPercent }.min()
        let brightestShadow = items.compactMap { $0.entries.max { $0.requestedEV < $1.requestedEV }?.analysis.shadowClippingPercent }.min()
        return "n=\(items.count) · auto \(auto.rawValue)"
            + (darkestClip.map { String(format: " (darkest highlight clip %.2f%%", $0) } ?? " (")
            + (brightestShadow.map { String(format: ", brightest shadow clip %.2f%%)", $0) } ?? ")")
            + " · window detail \(manual(.windowDetailInDarkestFrame).rawValue)"
            + " · EV0 \(manual(.referenceExposureValid).rawValue)"
            + " · shadows \(manual(.interiorShadowsInBrightestFrame).rawValue)"
    }

    /// Per-EV statistics across every analysed bracket: which exposures add little information.
    private nonisolated static func redundancyLines(_ items: [Analysed]) -> [String] {
        let entries = items.flatMap(\.entries)
        guard !entries.isEmpty else { return ["PENDING (no analysed brackets)"] }
        let grouped = Dictionary(grouping: entries) { ($0.requestedEV * 100).rounded() / 100 }
        var lines = grouped.keys.sorted().map { ev -> String in
            let group = grouped[ev] ?? []
            let lum = mean(group.map(\.analysis.meanLuminance)) ?? 0
            let highlights = mean(group.map(\.analysis.highlightClippingPercent)) ?? 0
            let shadows = mean(group.map(\.analysis.shadowClippingPercent)) ?? 0
            var flag = ""
            if group.allSatisfy({ $0.analysis.meanLuminance > BracketDynamicRangeReport.unusableBrightMean }) {
                flag = " ← always blown out"
            } else if group.allSatisfy({ $0.analysis.meanLuminance < BracketDynamicRangeReport.unusableDarkMean }) {
                flag = " ← always near black"
            }
            return String(format: "EV %@: n=%d · mean lum %.2f · highlight clip %.1f%% · shadow clip %.1f%%%@",
                          CaptureProfile.evLabel(ev), group.count, lum, highlights, shadows, flag)
        }
        let pairs = items.flatMap { $0.range?.redundantPairs ?? [] }
        let pairCounts = Dictionary(grouping: pairs.map { $0.map { CaptureProfile.evLabel($0) }.joined(separator: "↔") }, by: { $0 })
        if pairCounts.isEmpty {
            lines.append("Redundant adjacent pairs: none")
        } else {
            lines.append("Redundant adjacent pairs: " + pairCounts.map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", "))
        }
        lines.append("No frame is removed automatically; use this to choose the calibrated profile.")
        return lines
    }

    private nonisolated static func storageLines(_ valid: [CaptureManifest]) -> [String] {
        let frames = valid.flatMap(\.frames).map { Double($0.byteCount) }
        guard !frames.isEmpty else { return ["Average frame: PENDING", "Average bracket: PENDING"] }
        var lines = [
            "Average frame: \(bytes(mean(frames)))",
            "Average bracket: \(bytes(mean(valid.map { Double($0.totalByteCount) })))",
        ]
        let byProfile = Dictionary(grouping: valid, by: \.captureProfile.devLabel)
        for (profile, items) in byProfile.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(profile) bracket: \(bytes(mean(items.map { Double($0.totalByteCount) }))) (n=\(items.count))")
        }
        if byProfile["FULL_9"] == nil { lines.append("  FULL_9 bracket: not captured on this device") }
        return lines
    }

    private nonisolated static func healthLines(_ runs: [ValidationRun]) -> [String] {
        guard !runs.isEmpty else { return ["Findings: PENDING"] }
        let memory = runs.compactMap(\.memoryFootprintMB)
        let thermal = Dictionary(grouping: runs, by: \.thermalState).mapValues(\.count)
        let hot = runs.filter { $0.thermalState == "SERIOUS" || $0.thermalState == "CRITICAL" }.count
        return [
            "Memory: first \(mb(memory.first)) · last \(mb(memory.last)) · peak \(mb(memory.max()))",
            "Thermal: " + thermal.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "),
            "Findings: " + (hot > 0 ? "\(hot) bracket(s) at SERIOUS/CRITICAL thermal state" : "no serious thermal state recorded"),
        ]
    }

    /// True when some 20 consecutive shutter actions all succeeded.
    private nonisolated static func hasConsecutive(_ runs: [ValidationRun], length: Int) -> Bool {
        var streak = 0
        for run in runs.sorted(by: { $0.at < $1.at }) {
            streak = run.succeeded ? streak + 1 : 0
            if streak >= length { return true }
        }
        return false
    }

    /// Three successful, distinct captures within 20 seconds.
    private nonisolated static func hasRapidBurst(_ runs: [ValidationRun]) -> Bool {
        let ordered = runs.sorted { $0.at < $1.at }
        guard ordered.count >= 3 else { return false }
        for index in 0...(ordered.count - 3) {
            let window = ordered[index...(index + 2)]
            guard let first = window.first, let last = window.last else { continue }
            if last.at.timeIntervalSince(first.at) <= 20, Set(window.map(\.clientCaptureID)).count == 3 {
                return true
            }
        }
        return false
    }

    // MARK: - Formatting

    private nonisolated static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "PENDING"
    }

    private nonisolated static func mb(_ value: Double?) -> String {
        value.map { String(format: "%.0f MB", $0) } ?? "—"
    }

    private nonisolated static func bytes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
