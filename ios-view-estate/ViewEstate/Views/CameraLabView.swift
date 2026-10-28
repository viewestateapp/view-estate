import SwiftUI

/// Development-only Camera Lab: everything needed to calibrate the real camera on a physical
/// iPhone before HDR exists. Reachable only from the developer panel — never from production UI.
struct CameraLabView: View {
    @Environment(AppState.self) private var state

    @State private var stability = CameraStabilityService()
    @State private var manifests: [CaptureManifest] = []
    @State private var exportURL: URL?
    @State private var exportMessage: String?
    @State private var isExporting = false
    @State private var truthCheck = Full9TruthCheckModel()

    private var diagnostics: CameraDiagnostics { state.cameraDiagnostics }
    private var calibration: CameraCalibrationProfile { diagnostics.calibration }
    private var lastQuality: CaptureQualityReport? { diagnostics.lastManifest?.quality }

    /// The most recent native (camera) capture: this run's last bracket, else the newest bundle on disk.
    private var lastPhysicalManifest: CaptureManifest? {
        if let manifest = diagnostics.lastManifest, manifest.captureSource == .nativeReal { return manifest }
        return manifests.first { $0.captureSource == .nativeReal }
    }

    var body: some View {
        List {
            full9Section
            validationSection
            deviceSection
            calibrationSection
            liveStabilitySection
            lastBracketSection
            sessionSection
            qaSection
            storageSection
            datasetSection
            recentSection
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Camera Lab")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear {
            stability.apply(calibration)
            stability.start()
            reload()
        }
        .onDisappear { stability.stop() }
    }

    // MARK: - FULL_9 truth check

    private var full9Section: some View {
        Section {
            if let manifest = lastPhysicalManifest {
                if PhysicalValidationStore.isSimulator {
                    note("SIMULATOR — not physical evidence.")
                }
                row("Captured", manifest.startedAt.formatted(date: .abbreviated, time: .standard))
                row("Device", manifest.device)
                if let check = truthCheck.check {
                    Full9TruthCheckRows(check: check)
                }
                NavigationLink {
                    ExposureTruthInspectorView(manifest: manifest)
                } label: {
                    link("Inspect \(manifest.requestedLadder.count) exposures")
                }
            } else {
                note("No native capture on this device yet. Take one FULL_9 photo, then return here.")
            }
        } header: {
            Text("FULL_9 truth check · last physical capture")
        } footer: {
            Text("Two native bracket requests (5 + 4) sound like 2–3 shutter events. Only callbacks, files, hashes and exposure levels decide the verdict.")
        }
        .listRowBackground(VE.surface)
        .task(id: lastPhysicalManifest?.clientCaptureID) {
            if let manifest = lastPhysicalManifest { await truthCheck.measure(manifest) }
        }
    }

    // MARK: - Physical validation (D3-V)

    private var validationSection: some View {
        Section("Physical validation · D3-V") {
            if PhysicalValidationStore.isSimulator {
                note("Simulator: sessions here never count as evidence. Run this on a physical iPhone.")
            }
            if let session = state.validationSession {
                row("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                row("Device", "\(session.deviceModel) · \(session.systemVersion)")
                row("Shutter actions", "\(session.runs.count) (\(session.runs.filter(\.succeeded).count) valid)")
                row("Offline brackets", "\(session.runs.filter { $0.capturedOffline && $0.succeeded }.count)")
                row("App launches", "\(session.launchCount)")
                row("Session interruptions / recoveries", "\(session.events.filter { $0.kind == .interrupted || $0.kind == .runtimeError }.count) / \(session.events.filter { $0.kind == .recovered }.count)")
                row("Duplicate clientCaptureID", "\(session.duplicateClientCaptureIDs)")
                row("Credits before / now", "\(session.creditsBefore) / \(state.wallet.total)")
                row("Manual checks", "\(ManualValidationCheck.allCases.filter { session.verdict($0) != .pending }.count)/\(ManualValidationCheck.allCases.count) recorded")
                row("Decision", session.decision.rawValue)
                NavigationLink {
                    PhysicalValidationChecklistView()
                } label: {
                    link("Human checks, ultra-wide & profile")
                }
                NavigationLink {
                    CameraCalibrationReportView()
                } label: {
                    link("Final camera calibration report")
                }
                Button(role: .destructive) {
                    state.discardValidationSession()
                } label: {
                    Text("Discard validation session")
                        .font(.system(size: 14, weight: .medium))
                }
            } else {
                note("Start a session before the first test capture. It records every shutter action, camera interruption and the credit balance, and survives app restarts. Only captures after the start count as evidence.")
                Button {
                    state.startValidationSession()
                } label: {
                    link("Start validation session")
                }
            }
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Device & camera

    private var deviceSection: some View {
        Section("Device") {
            row("Device", diagnostics.capabilities?.deviceModel ?? CameraService.deviceModelName())
            row("iOS", diagnostics.capabilities?.systemVersion ?? "iOS " + UIDevice.current.systemVersion)
            row("App build", CaptureManifestBuilder.appVersion)
            row("Physical camera", diagnostics.setup?.deviceID ?? lastQuality?.lens?.cameraUniqueID ?? "—")
            row("Lens", diagnostics.setup?.lens ?? "—")
            if let lens = lastQuality?.lens {
                row("Device type", lens.deviceType)
                row("Focal length", lens.focalLengthMM.map { String(format: "%.2f mm", $0) } ?? "—")
                row("35 mm equivalent", lens.focalLengthEquivalentMM.map { String(format: "%.0f mm", $0) } ?? "—")
                row("Field of view", lens.fieldOfViewDegrees.map { String(format: "%.1f°", $0) } ?? "—")
                row("Zoom factor", String(format: "%.2f×", lens.zoomFactor))
                row("Calibration data", lens.calibrationDataSupported ? "SUPPORTED" : "UNSUPPORTED")
            }
            if let capabilities = diagnostics.capabilities {
                row("Exposure bias", "\(capabilities.minExposureBiasDescription) … \(capabilities.maxExposureBiasDescription)")
                row("Max bracket", "\(capabilities.maxBracketCount)")
                row("Focus / WB lock", "\(capabilities.supportsFocusLock ? "YES" : "NO") / \(capabilities.supportsWhiteBalanceLock ? "YES" : "NO")")
            } else {
                note("Open the native camera once to read the real capabilities.")
            }
        }
        .listRowBackground(VE.surface)
    }

    private var calibrationSection: some View {
        Section("Calibration profile") {
            row("Profile", calibration.versionLabel)
            row("Status", calibration.status.devLabel)
            row("Device match", calibration.deviceModel)
            row("iOS range", calibration.osVersionRange.devLabel)
            row("Preferred lens", calibration.preferredLens.devLabel)
            row("Profile ceiling", calibration.captureProfile?.devLabel ?? "HARDWARE MAX")
            row("Device ladder", calibration.exposureValues.map { $0.map { CaptureProfile.evLabel($0) }.joined(separator: " ") } ?? "—")
            if let plan = diagnostics.plan {
                row("Active profile", "\(plan.profile.devLabel) · \(plan.ladderSource.devLabel)")
                row("Active ladder", plan.ladderDescription)
                row("Bracket requests", plan.segmentDescription)
            }
            row("Window / stable", String(format: "%.0f / %.0f ms", calibration.stabilityThresholds.stabilityWindowMs, calibration.stabilityThresholds.minimumStableDurationMs))
            row("Max rot / acc var", String(format: "%.4f / %.4f", calibration.stabilityThresholds.maxRotationVariance, calibration.stabilityThresholds.maxAccelerationVariance))
            row("Severe rot / acc", String(format: "%.2f rad/s / %.2f g", calibration.stabilityThresholds.severeRotationRate, calibration.stabilityThresholds.severeAcceleration))
            row("Block when severe", calibration.stabilityThresholds.blockCaptureWhenSevere ? "YES" : "NO")
            row("Level tolerance", String(format: "±%.1f°", calibration.levelToleranceDegrees))
            row("Focus", calibration.focusStrategy.devLabel)
            row("White balance", calibration.whiteBalanceStrategy.devLabel)
            row("Metering", calibration.exposureStrategy.metering.rawValue)

            Picker("Lens test", selection: lensBinding) {
                Text("Calibration").tag(PreferredLens?.none)
                ForEach(PreferredLens.allCases, id: \.self) { lens in
                    Text(lens.devLabel).tag(PreferredLens?.some(lens))
                }
            }
            .pickerStyle(.segmented)
            note("Lens choice applies the next time the camera opens. Never switched during a bracket.")
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Live

    private var liveStabilitySection: some View {
        let reading = stability.reading
        return Section("Live stability & level") {
            if stability.isSensorAvailable {
                row("State", reading.state.devLabel)
                row("Stability score", String(format: "%.2f", reading.score))
                row("Rotation variance", String(format: "%.5f (rad/s)²", reading.rotationVariance))
                row("Acceleration variance", String(format: "%.5f g²", reading.accelerationVariance))
                row("Peak rotation", String(format: "%.3f rad/s", reading.peakRotation))
                row("Peak acceleration", String(format: "%.3f g", reading.peakAcceleration))
                row("Severe", reading.isSevere ? "YES — shutter held" : "NO")
                row("Roll", String(format: "%+.2f°", reading.rollDegrees))
                row("Pitch", String(format: "%+.2f°", reading.pitchDegrees))
                row("Level", reading.isLevel ? "READY" : "GUIDE")
                ScoreBar(value: reading.score)
            } else {
                note("No motion sensor on this device (simulator). Physical iPhone required.")
            }
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Last bracket

    @ViewBuilder
    private var lastBracketSection: some View {
        Section("Last bracket") {
            if let manifest = diagnostics.lastManifest {
                row("State", manifest.state.devLabel)
                row("Frames", manifest.frameCountDescription)
                row("Ladder", manifest.requestedLadder.map { CaptureProfile.evLabel($0) }.joined(separator: " "))
                if let failure = manifest.failureCode { row("Failure", failure) }
                if let quality = manifest.quality {
                    row("Quality", quality.qualityClass.devLabel)
                    if !quality.qualityReasons.isEmpty {
                        note(quality.qualityReasons.joined(separator: " · "))
                    }
                    row("Stability score", quality.stabilityScore.map { String(format: "%.2f", $0) } ?? "—")
                    row("Motion", quality.motionWarning.devLabel)
                    row("Max rotation", quality.motion.maxRotationDuringCapture.map { String(format: "%.3f rad/s", $0) } ?? "—")
                    row("Max acceleration", quality.motion.maxAccelerationDuringCapture.map { String(format: "%.3f g", $0) } ?? "—")
                    row("Roll / pitch at tap", angles(quality.rollAngle, quality.pitchAngle))
                    row("Focus", "\(quality.focusStatus.devLabel) · lock \(quality.focusLockSucceeded ? "YES" : "NO")")
                    row("Focus timeout / shift", "\(quality.focusTimeout ? "YES" : "NO") / \(quality.focusShiftDetected ? "YES" : "NO")")
                    row("White balance lock", quality.whiteBalanceLockSucceeded ? "YES" : "NO")
                    row("WB variation", quality.whiteBalanceVariation ? "YES" : "NO")
                    if let reference = quality.whiteBalanceReference { note(reference.devLabel) }
                    row("EV0 reference", quality.exposureReferenceEstablished ? "ESTABLISHED" : "UNSETTLED")
                    row("Tap → capture", ms(quality.tapToCaptureStartMs))
                    row("Preparation", ms(quality.preparationMs))
                    row("Bracket duration", ms(quality.bracketDurationMs))
                    row("Exposure span", ms(quality.exposureSpanMs))
                    row("Frame intervals", quality.frameIntervalsMs.map { String(format: "%.0f", $0) }.joined(separator: " · "))
                    row("Thermal / memory", "\(quality.thermalState ?? "—") / \(quality.memoryFootprintMB.map { String(format: "%.0f MB", $0) } ?? "—")")
                }
                NavigationLink {
                    DevFrameInspectorView(manifest: manifest)
                } label: {
                    link("Inspect \(manifest.frames.count) exposures · histograms")
                }
            } else {
                note("No native bracket captured in this run.")
            }
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Repeated capture

    private var sessionSection: some View {
        let runs = diagnostics.sessionRuns
        let succeeded = runs.filter(\.succeeded)
        return Section("Repeated capture · this session") {
            row("Shutter actions", "\(runs.count) (\(succeeded.count) valid)")
            row("Duplicate clientCaptureID", "\(diagnostics.duplicateAttemptCount)")
            row("Avg duration · first 5", ms(average(succeeded.prefix(5).compactMap(\.bracketDurationMs))))
            row("Avg duration · last 5", ms(average(succeeded.suffix(5).compactMap(\.bracketDurationMs))))
            row("Memory · first / last", "\(mb(runs.first?.memoryFootprintMB)) / \(mb(runs.last?.memoryFootprintMB))")
            row("Memory · peak", mb(runs.compactMap(\.memoryFootprintMB).max()))
            row("Thermal · now", DeviceHealthProbe.thermalStateLabel())
            let failures = runs.compactMap(\.failureCode)
            if !failures.isEmpty {
                note("Failures: " + failures.joined(separator: ", "))
            }
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - QA protocol

    private var qaSection: some View {
        Section("Physical QA protocol") {
            Toggle("Tag next captures", isOn: taggingBinding)
                .tint(VE.copper)
            if let tag = state.qaTag {
                Picker("Scene", selection: sceneBinding(tag)) {
                    ForEach(QAScene.allCases) { scene in
                        Text("\(scene.rawValue) · \(scene.title)").tag(scene)
                    }
                }
                Picker("Hold", selection: conditionBinding(tag)) {
                    ForEach(QAHoldCondition.allCases) { condition in
                        Text(condition.rawValue).tag(condition)
                    }
                }
                .pickerStyle(.segmented)
            }
            ForEach(QAScene.allCases) { scene in
                let count = manifests.filter { $0.qaTag?.scene == scene && $0.state.isValid }.count
                HStack {
                    Image(systemName: count > 0 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(count > 0 ? VE.success : VE.textTertiary)
                    Text("\(scene.rawValue) · \(scene.title)")
                        .font(.system(size: 13))
                        .foregroundStyle(VE.textSecondary)
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VE.textPrimary)
                }
            }
            note("Residência Sergio may be used as the QA property. Its SketchUp source is never camera input.")
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Storage

    private var storageSection: some View {
        let frames = diagnostics.plan?.expectedFrameCount ?? 9
        return Section("Storage preflight") {
            row("Available", bytes(state.devAvailableBytesOverride ?? CaptureStoragePolicy.availableBytes()))
            row("Needed for \(frames) frames", bytes(CaptureStoragePolicy.requiredBytes(frameCount: frames, averageFrameBytes: nil)))
            Toggle("Simulate low storage", isOn: lowStorageBinding)
                .tint(VE.warning)
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Dataset & report

    private var datasetSection: some View {
        Section("Dataset & report") {
            Button {
                Task { await exportDataset() }
            } label: {
                HStack {
                    link(isExporting ? "Building dataset…" : "Build QA dataset (tagged captures only)")
                    Spacer()
                    if isExporting { ProgressView().tint(VE.copper) }
                }
            }
            .disabled(isExporting)
            if let exportURL {
                ShareLink(item: exportURL) {
                    link("Share \(exportURL.lastPathComponent)")
                }
            }
            if let exportMessage { note(exportMessage) }
            note("Source photographs stay on this device. Nothing is sent to analytics; only tagged QA captures are exported.")
        }
        .listRowBackground(VE.surface)
    }

    private var recentSection: some View {
        Section("Recent brackets on device") {
            if manifests.isEmpty { note("No capture bundles on this device.") }
            ForEach(manifests.prefix(20)) { manifest in
                NavigationLink {
                    DevFrameInspectorView(manifest: manifest)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(manifest.captureProfile.devLabel) · \(manifest.frameCountDescription) · \(manifest.quality?.qualityClass.devLabel ?? manifest.state.devLabel)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(VE.textPrimary)
                        Text("\(manifest.startedAt.formatted(date: .abbreviated, time: .standard))\(manifest.qaTag.map { " · \($0.scene.rawValue)/\($0.condition.rawValue)" } ?? "")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(VE.textTertiary)
                    }
                }
            }
        }
        .listRowBackground(VE.surface)
    }

    // MARK: - Actions

    private func reload() {
        manifests = CaptureBundleStore.allManifests()
    }

    private func exportDataset() async {
        isExporting = true
        exportMessage = nil
        let snapshot = manifests
        let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
            Result { try CameraQADatasetExporter.export(snapshot) }
        }.value
        switch result {
        case .success(let url):
            exportURL = url
        case .failure(let error):
            exportURL = nil
            exportMessage = (error as? CameraQADatasetExporter.ExportError) == .nothingTagged
                ? "No tagged valid captures yet. Turn on tagging and photograph a test scene."
                : "Dataset could not be built."
        }
        isExporting = false
    }

    // MARK: - Bindings

    private var lensBinding: Binding<PreferredLens?> {
        Binding(get: { state.devLensOverride }, set: { state.devLensOverride = $0 })
    }

    private var lowStorageBinding: Binding<Bool> {
        Binding(get: { state.devSimulateLowStorage }, set: { state.devSimulateLowStorage = $0 })
    }

    private var taggingBinding: Binding<Bool> {
        Binding(
            get: { state.qaTag != nil },
            set: { enabled in
                state.qaTag = enabled ? CameraQATag(scene: .livingRoomWindow, condition: .handheld) : nil
            }
        )
    }

    private func sceneBinding(_ tag: CameraQATag) -> Binding<QAScene> {
        Binding(get: { state.qaTag?.scene ?? tag.scene }, set: { state.qaTag?.scene = $0 })
    }

    private func conditionBinding(_ tag: CameraQATag) -> Binding<QAHoldCondition> {
        Binding(get: { state.qaTag?.condition ?? tag.condition }, set: { state.qaTag?.condition = $0 })
    }

    // MARK: - Formatting

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private func mb(_ value: Double?) -> String {
        value.map { String(format: "%.0f MB", $0) } ?? "—"
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func angles(_ roll: Double?, _ pitch: Double?) -> String {
        guard let roll, let pitch else { return "—" }
        return String(format: "%+.1f° / %+.1f°", roll, pitch)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VE.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(VE.textTertiary)
    }

    private func link(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(VE.copper)
    }
}

/// Live stability score, development only.
private struct ScoreBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(VE.elevated)
                Capsule()
                    .fill(value >= 0.5 ? VE.success : VE.warning)
                    .frame(width: geometry.size.width * max(0, min(1, value)))
                    .animation(.easeOut(duration: 0.12), value: value)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

