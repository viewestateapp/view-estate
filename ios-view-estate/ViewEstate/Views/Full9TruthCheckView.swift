import SwiftUI

/// Development-only: re-measures one bracket from disk and builds its FULL_9 truth check.
@MainActor
@Observable
final class Full9TruthCheckModel {
    private(set) var check: Full9TruthCheck?
    /// Frames whose file exists with the recorded size and whose SHA-256 still matches.
    private(set) var realFrames: [CaptureFrame] = []
    private(set) var isMeasuring = false
    private var measuredID: UUID?

    func measure(_ manifest: CaptureManifest, force: Bool = false) async {
        guard force || measuredID != manifest.clientCaptureID || check == nil else { return }
        measuredID = manifest.clientCaptureID
        isMeasuring = true
        check = Full9TruthCheck(manifest: manifest, live: nil)
        let frames = manifest.orderedFrames
        let plan = BracketPlan(profile: manifest.captureProfile, segments: [manifest.requestedLadder], reason: "")
        let (audit, verified) = await Task.detached(priority: .utility) { () -> (BracketAudit, [CaptureFrame]) in
            let audit = BracketAuditor.audit(frames: frames, plan: plan, evidence: .unknown, verifyFromDisk: true)
            let verified = frames.filter { frame in
                guard frame.byteCount > 0, CaptureBundleStore.fileSize(frame) == frame.byteCount,
                      let data = CaptureBundleStore.loadData(frame)
                else { return false }
                return CaptureBundleStore.checksum(data) == frame.checksum
            }
            return (audit, verified)
        }.value
        guard measuredID == manifest.clientCaptureID else { return }
        check = Full9TruthCheck(manifest: manifest, live: audit)
        realFrames = verified
        isMeasuring = false
    }
}

/// The FULL_9 truth-check rows, shared by the Camera Lab and the exposure inspector.
struct Full9TruthCheckRows: View {
    let check: Full9TruthCheck

    var body: some View {
        Group {
            HStack {
                Text("FULL_9")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(VE.textPrimary)
                Spacer()
                Text(check.verdict.rawValue)
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundStyle(verdictColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(verdictColor.opacity(0.16), in: .capsule)
            }
            row("Requested exposures", "\(check.requestedExposures)", bad: check.requestedExposures != 9)
            row("Native AVCapturePhoto requests", check.nativeRequests.map(String.init) ?? "not recorded",
                bad: check.nativeRequests != Full9TruthCheck.requiredNativeRequests)
            ForEach(check.requests, id: \.number) { request in
                row("Request \(request.number) expectedPhotoCount",
                    request.expectedPhotoCount.map(String.init) ?? "not recorded")
                row("Request \(request.number) callbacks received",
                    request.callbacks.map(String.init) ?? "not recorded",
                    bad: request.callbacks == nil || (request.callbacks ?? 0) < (request.expectedPhotoCount ?? 0))
            }
            row("Total didFinishProcessingPhoto callbacks", check.totalCallbacks.map(String.init) ?? "not recorded",
                bad: (check.totalCallbacks ?? 0) < 9)
            row("Files persisted", "\(check.filesPersisted)", bad: check.filesPersisted < 9)
            row("Unique file hashes", "\(check.uniqueHashes)", bad: check.uniqueHashes < 9)
            row("Distinct exposure levels", "\(check.distinctExposureLevels)", bad: check.distinctExposureLevels < 9)
            row("EV0 count", "\(check.ev0Count)", bad: check.ev0Count != 1)
            row("Final real frame count", "\(check.realFrames)", bad: check.realFrames < 9)
            row("Actual capture profile", check.actualProfile.devLabel, bad: check.actualProfile != .full9)
            if let source = check.expectedPhotoCountSource {
                row("expectedPhotoCount source", source)
            }
            if check.verdict == .notApplicable {
                note("Last capture was \(check.requestedProfile.devLabel), not FULL_9.")
            }
            ForEach(check.failures, id: \.self) { failure in
                Text("✗ " + failure)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(VE.danger)
            }
        }
    }

    private var verdictColor: Color {
        switch check.verdict {
        case .pass: VE.success
        case .fail: VE.danger
        case .notApplicable: VE.textTertiary
        }
    }

    private func row(_ label: String, _ value: String, bad: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(bad && check.verdict != .notApplicable ? VE.warning : VE.textPrimary)
                .lineLimit(1)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(VE.textTertiary)
    }
}

/// "Inspect 9 exposures": only the real persisted exposure files of one capture, re-verified
/// from disk (file exists, size matches, SHA-256 matches). Nothing is synthesised or substituted.
struct ExposureTruthInspectorView: View {
    let manifest: CaptureManifest

    @State private var model = Full9TruthCheckModel()

    var body: some View {
        List {
            Section("Truth check") {
                if let check = model.check {
                    Full9TruthCheckRows(check: check)
                }
            }
            .listRowBackground(VE.surface)

            Section {
                if model.isMeasuring {
                    HStack {
                        ProgressView().tint(VE.textTertiary)
                        Text("Verifying files on disk…")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                } else if model.realFrames.isEmpty {
                    Text("No real exposure file is on disk for this capture.")
                        .font(.system(size: 13))
                        .foregroundStyle(VE.warning)
                }
                ForEach(model.realFrames) { frame in
                    NavigationLink {
                        DevFrameViewer(frame: frame)
                    } label: {
                        frameRow(frame)
                    }
                }
            } header: {
                Text("Real persisted exposures · \(model.realFrames.count)")
            } footer: {
                Text("photoCount / expectedPhotoCount is native on a physical iPhone. \"~\" marks callback arrival order over the requested count when the device did not report it.")
            }
            .listRowBackground(VE.surface)
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Inspect \(manifest.requestedLadder.count) exposures")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task(id: manifest.clientCaptureID) { await model.measure(manifest) }
    }

    private func frameRow(_ frame: CaptureFrame) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("EV \(frame.evLabel)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(frame.isReferenceExposure ? VE.copper : VE.textPrimary)
                Text("req \(frame.requestNumber.map(String.init) ?? "?")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VE.textSecondary)
                Text(frame.photoCountDescription)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VE.textSecondary)
                Spacer()
                Text(frame.hashSuffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VE.textTertiary)
            }
            detail("requested \(frame.evLabel) · actual bias \(frame.actualBiasDescription)")
            detail("\(frame.isoDescription) · \(frame.exposureDescription)")
            detail("\(frame.fileName) · \(frame.sizeDescription)")
        }
        .padding(.vertical, 3)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(VE.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
