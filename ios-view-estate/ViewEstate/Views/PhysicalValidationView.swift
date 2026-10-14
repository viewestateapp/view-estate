import SwiftUI

/// Development-only: observations a person makes on the physical iPhone, plus the ultra-wide
/// classification and the profile chosen from the evidence. Never reachable from production UI.
struct PhysicalValidationChecklistView: View {
    @Environment(AppState.self) private var state

    private var groups: [(String, [ManualValidationCheck])] {
        var order: [String] = []
        var grouped: [String: [ManualValidationCheck]] = [:]
        for check in ManualValidationCheck.allCases {
            if grouped[check.group] == nil { order.append(check.group) }
            grouped[check.group, default: []].append(check)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if state.validationSession == nil {
                Section {
                    Text("Start a validation session in the Camera Lab first.")
                        .font(.system(size: 13))
                        .foregroundStyle(VE.textTertiary)
                }
                .listRowBackground(VE.surface)
            } else {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { check in
                            checkRow(check)
                        }
                    }
                    .listRowBackground(VE.surface)
                }
                ultraWideSection
                profileSection
                notesSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Human checks")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func checkRow(_ check: ManualValidationCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(check.title + (check.isOptional ? " · optional" : ""))
                .font(.system(size: 13))
                .foregroundStyle(VE.textSecondary)
            Picker(check.title, selection: Binding(
                get: { state.validationSession?.verdict(check) ?? .pending },
                set: { state.setManualCheck(check, $0) }
            )) {
                ForEach(ValidationVerdict.allCases, id: \.self) { verdict in
                    Text(verdict.rawValue).tag(verdict)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private var ultraWideSection: some View {
        Section("Ultra-wide lens · separate test") {
            Picker("Classification", selection: Binding(
                get: { state.validationSession?.ultraWide ?? .pending },
                set: { value in state.updateValidation { $0.ultraWide = value } }
            )) {
                ForEach(LensClassification.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            TextField("Edge distortion, corners, noise, focus, bracket support…", text: Binding(
                get: { state.validationSession?.ultraWideNotes ?? "" },
                set: { value in state.updateValidation { $0.ultraWideNotes = value } }
            ), axis: .vertical)
            .font(.system(size: 13))
            Text("Use Camera Lab → Lens test → ULTRA_WIDE, then reopen the camera. It never becomes the default from this test.")
                .font(.system(size: 12))
                .foregroundStyle(VE.textTertiary)
        }
        .listRowBackground(VE.surface)
    }

    private var profileSection: some View {
        Section("Profile chosen from evidence") {
            Picker("Recommended", selection: Binding(
                get: { state.validationSession?.recommendedProfile ?? "" },
                set: { value in state.updateValidation { $0.recommendedProfile = value.isEmpty ? nil : value } }
            )) {
                Text("PENDING").tag("")
                ForEach(CaptureProfile.allCases.filter(\.isBracket)) { profile in
                    Text(profile.devLabel).tag(profile.devLabel)
                }
                Text("CUSTOM").tag("CUSTOM")
            }
            if state.validationSession?.recommendedProfile == "CUSTOM" {
                TextField("Custom ladder, e.g. -2.5 -1.5 -0.5 0 0.5 1.5 2.5", text: Binding(
                    get: { state.validationSession?.customLadder ?? "" },
                    set: { value in state.updateValidation { $0.customLadder = value } }
                ))
                .font(.system(size: 13, design: .monospaced))
            }
            Text("Base it on dynamic range, duration, motion risk and redundant frames — never on frame count alone.")
                .font(.system(size: 12))
                .foregroundStyle(VE.textTertiary)
        }
        .listRowBackground(VE.surface)
    }

    private var notesSection: some View {
        Section("Tester notes · known limitations") {
            TextField("Anything observed that the numbers do not show", text: Binding(
                get: { state.validationSession?.notes ?? "" },
                set: { value in state.updateValidation { $0.notes = value } }
            ), axis: .vertical)
            .font(.system(size: 13))
        }
        .listRowBackground(VE.surface)
    }
}

/// The Final Camera Calibration Report, the section-33 gate and the human sign-off.
struct CameraCalibrationReportView: View {
    @Environment(AppState.self) private var state
    @State private var output: CameraCalibrationReportBuilder.Output?
    @State private var signer: String = ""

    var body: some View {
        List {
            if let output {
                gateSection(output)
                decisionSection(output)
                Section("Report") {
                    Text(output.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VE.textPrimary)
                        .textSelection(.enabled)
                }
                .listRowBackground(VE.surface)
            } else {
                ProgressView("Analysing frames…")
                    .tint(VE.copper)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Calibration report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let output {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: output.text)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            signer = state.validationSession?.signedOffBy ?? ""
            await rebuild()
        }
    }

    private func gateSection(_ output: CameraCalibrationReportBuilder.Output) -> some View {
        Section("Calibration gate") {
            ForEach(output.gate) { item in
                HStack {
                    Text(item.name)
                        .font(.system(size: 13))
                        .foregroundStyle(VE.textSecondary)
                    Spacer()
                    Text(item.verdict.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(item.verdict))
                }
            }
            Text("Automatic suggestion: \(output.suggestion.rawValue). It is never applied by itself.")
                .font(.system(size: 12))
                .foregroundStyle(VE.textTertiary)
        }
        .listRowBackground(VE.surface)
    }

    private func decisionSection(_ output: CameraCalibrationReportBuilder.Output) -> some View {
        Section("Human sign-off") {
            ForEach(CalibrationDecision.allCases, id: \.self) { decision in
                let locked = decision == .calibrated && !output.calibratedAllowed
                Button {
                    sign(decision)
                } label: {
                    HStack {
                        Text(decision.rawValue)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(locked ? VE.textTertiary : VE.textPrimary)
                        Spacer()
                        if state.validationSession?.decision == decision {
                            Image(systemName: "checkmark")
                                .foregroundStyle(VE.copper)
                        }
                    }
                }
                .disabled(locked || !output.evidenceAllowed || (decision != .pending && signer.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            TextField("Signed off by (name)", text: $signer)
                .font(.system(size: 13))
            Text(output.calibratedAllowed
                 ? "Every gate item passed on this iPhone. CALIBRATED may be signed."
                 : "CALIBRATED stays locked until every gate item is PASS on a physical iPhone.")
                .font(.system(size: 12))
                .foregroundStyle(VE.textTertiary)
        }
        .listRowBackground(VE.surface)
    }

    private func sign(_ decision: CalibrationDecision) {
        let name = signer.trimmingCharacters(in: .whitespaces)
        state.updateValidation {
            $0.decision = decision
            $0.signedOffBy = decision == .pending ? "" : name
            $0.signedOffAt = decision == .pending ? nil : .now
        }
        Task { await rebuild() }
    }

    private func rebuild() async {
        let manifests = CaptureBundleStore.allManifests()
        let invalid = Set(
            manifests
                .filter { $0.state.isValid && CaptureBundleValidator.validate($0) != nil }
                .map(\.clientCaptureID)
        )
        let input = CameraCalibrationReportBuilder.Input(
            diagnostics: state.cameraDiagnostics,
            manifests: manifests,
            appVersion: CaptureManifestBuilder.appVersion,
            session: state.validationSession,
            creditsNow: state.wallet.total,
            creditTransactionsNow: state.transactions.count,
            isSimulator: PhysicalValidationStore.isSimulator,
            currentLaunchID: PhysicalValidationStore.currentLaunchID,
            invalidAcceptedIDs: invalid
        )
        output = await Task.detached(priority: .utility) {
            CameraCalibrationReportBuilder.build(input)
        }.value
    }

    private func color(_ verdict: ValidationVerdict) -> Color {
        switch verdict {
        case .pass: VE.success
        case .fail: VE.warning
        case .pending: VE.textTertiary
        }
    }
}
