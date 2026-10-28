import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Development-only inspection of one real bracket, exposure by exposure.
///
/// This is how a bracket is validated: not by counting nine files, but by seeing that −4 is
/// materially darker than 0 and +4 materially brighter, with the metadata to prove it. It is
/// never reachable by a normal user — only through the developer panel.
struct DevFrameInspectorView: View {
    let manifest: CaptureManifest

    @Environment(AppState.self) private var state
    @State private var analyses: [UUID: FrameExposureAnalysis] = [:]
    @State private var rangeReport: BracketDynamicRangeReport?
    @State private var isAnalysing = true
    /// Re-measured from disk now, in addition to the audit recorded at capture time.
    @State private var liveAudit: BracketAudit?

    var body: some View {
        List {
            auditSection
            dynamicRangeSection
            Section("Capture") {
                row("Profile", manifest.captureProfile.devLabel)
                row("State", manifest.state.devLabel)
                row("Frames", manifest.frameCountDescription)
                row("Client Capture ID", String(manifest.clientCaptureID.uuidString.prefix(8)))
                row("Camera", manifest.lensType)
                row("Orientation", manifest.orientation.devLabel)
                row("Focus lock", manifest.focusLockSucceeded.devLabel)
                row("White balance lock", manifest.whiteBalanceLockSucceeded.devLabel)
                row("Bracket duration", manifest.bracketDurationDescription)
                row("Total size", manifest.totalSizeDescription)
                row("captureSource", manifest.captureSource.devLabel)
                row("hdrSource", manifest.hdrSource.devLabel)
                if let failureCode = manifest.failureCode {
                    row("Failure", failureCode)
                }
                if let quality = manifest.quality {
                    row("Quality", quality.qualityClass.devLabel)
                    row("Ladder source", quality.ladderSource.devLabel)
                    row("Calibration", quality.deviceCaptureProfileVersion)
                }
                if let tag = manifest.qaTag {
                    row("QA scene", "\(tag.scene.rawValue) · \(tag.condition.rawValue)")
                }
            }
            .listRowBackground(VE.surface)

            Section("Exposures · tap to open the real file") {
                ForEach(manifest.orderedFrames) { frame in
                    NavigationLink {
                        DevFrameViewer(frame: frame)
                    } label: {
                        frameRow(frame)
                    }
                }
            }
            .listRowBackground(VE.surface)
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Frame inspector")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task(id: manifest.clientCaptureID) { await analyse() }
    }

    /// What physically happened for this one shutter action — callbacks, files, hashes.
    private var auditSection: some View {
        Section("Bracket audit · real evidence") {
            if let audit = manifest.audit {
                BracketAuditRows(audit: audit)
            } else {
                Text("Captured before callback auditing existed — callbacks were not recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(VE.textTertiary)
            }
            if let liveAudit {
                row("Re-verified now · persisted", "\(liveAudit.persistedFiles)")
                row("Re-verified now · checksums OK", "\(liveAudit.verifiedChecksums)")
                row("Re-verified now · unique hashes", "\(liveAudit.uniqueHashes)")
            }
        }
        .listRowBackground(VE.surface)
    }

    /// Does the ladder actually widen usable dynamic range? Development heuristics only.
    private var dynamicRangeSection: some View {
        Section("Dynamic range · development") {
            if let report = rangeReport {
                row("Verdict", report.verdict)
                row("Darkest recovers highlights", report.darkestRecoversHighlights ? "YES" : "NO")
                row("Brightest recovers shadows", report.brightestRecoversShadows ? "YES" : "NO")
                row("Adjacent exposures distinct", report.adjacentExposuresDistinct ? "YES" : "NO")
                if !report.redundantPairs.isEmpty {
                    row("Redundant pairs", report.redundantPairs.map { pair in
                        pair.map { CaptureProfile.evLabel($0) }.joined(separator: "/")
                    }.joined(separator: "  "))
                }
                row("Unusable extremes", extremesDescription(report))
                if let highlight = report.referenceHighlightClipping, let shadow = report.referenceShadowClipping {
                    row("EV 0 clipping H / S", String(format: "%.2f%% / %.2f%%", highlight, shadow))
                }
            } else if isAnalysing {
                HStack {
                    ProgressView().tint(VE.textTertiary)
                    Text("Analysing exposures…")
                        .font(.system(size: 13))
                        .foregroundStyle(VE.textTertiary)
                }
            } else {
                Text("Needs at least two readable exposures.")
                    .font(.system(size: 13))
                    .foregroundStyle(VE.textTertiary)
            }
        }
        .listRowBackground(VE.surface)
    }

    private func analyse() async {
        isAnalysing = true
        let frames = manifest.orderedFrames
        let plan = BracketPlan(profile: manifest.captureProfile, segments: [manifest.requestedLadder], reason: "")
        liveAudit = await Task.detached(priority: .utility) {
            BracketAuditor.audit(frames: frames, plan: plan, evidence: .unknown, verifyFromDisk: true)
        }.value
        let results = await Task.detached(priority: .utility) { () -> [UUID: FrameExposureAnalysis] in
            var output: [UUID: FrameExposureAnalysis] = [:]
            for frame in frames {
                guard let url = CaptureBundleStore.url(for: frame),
                      let analysis = FrameExposureAnalyzer.analyze(url: url)
                else { continue }
                output[frame.id] = analysis
            }
            return output
        }.value
        analyses = results
        rangeReport = BracketDynamicRangeReport.evaluate(
            frames.compactMap { frame in
                results[frame.id].map { BracketDynamicRangeReport.Entry(requestedEV: frame.requestedEV, analysis: $0) }
            }
        )
        isAnalysing = false
    }

    private func frameRow(_ frame: CaptureFrame) -> some View {
        HStack(alignment: .top, spacing: VE.Space.s) {
            FrameThumbnail(frame: frame)
                .frame(width: 68, height: 68)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(VE.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("EV \(frame.evLabel)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(frame.isReferenceExposure ? VE.copper : VE.textPrimary)
                    Text("#\(frame.sequenceIndex)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VE.textTertiary)
                    if frame.isReferenceExposure {
                        Text("REFERENCE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(VE.copper)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(VE.copper.opacity(0.16), in: .capsule)
                    }
                }
                detail("bias \(frame.actualBiasDescription)")
                detail("\(frame.exposureDescription) · \(frame.isoDescription) · \(frame.apertureDescription)")
                detail("\(frame.dimensionDescription) · \(frame.sizeDescription)")
                detail(timingDescription(frame))
                if let whiteBalance = frame.whiteBalance {
                    detail("WB \(whiteBalance.devLabel)")
                }
                if let lensPosition = frame.lensPosition {
                    detail(String(format: "lens position %.4f", lensPosition))
                }
                if let analysis = analyses[frame.id] {
                    LuminanceHistogram(bins: analysis.histogram)
                        .frame(height: 28)
                        .padding(.vertical, 2)
                    detail(String(
                        format: "clip H %.2f%% · S %.2f%% · mean %.2f",
                        analysis.highlightClippingPercent,
                        analysis.shadowClippingPercent,
                        analysis.meanLuminance
                    ))
                }
                detail(frame.fileName)
                detail("sha256 …\(frame.checksum.suffix(12)) · \(frame.uploadState.devLabel)")
            }
        }
        .padding(.vertical, 4)
    }

    private func extremesDescription(_ report: BracketDynamicRangeReport) -> String {
        var parts: [String] = []
        if report.unusableDarkExtreme { parts.append("DARK") }
        if report.unusableBrightExtreme { parts.append("BRIGHT") }
        return parts.isEmpty ? "NONE" : parts.joined(separator: " + ")
    }

    private func timingDescription(_ frame: CaptureFrame) -> String {
        let ordered = manifest.orderedFrames
        let intervals = manifest.frameIntervalsMs
        let time = frame.capturedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        guard let index = ordered.firstIndex(where: { $0.id == frame.id }), index > 0, index - 1 < intervals.count else {
            return "t \(time)"
        }
        return String(format: "t %@ · +%.0f ms", time, intervals[index - 1])
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(VE.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
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
}

/// The audit rows shared by the developer panel and the frame inspector.
struct BracketAuditRows: View {
    let audit: BracketAudit

    var body: some View {
        Group {
            row("Verdict", audit.verdictLabel, highlight: !audit.isTruthful)
            row("Requested exposures", "\(audit.requestedExposures)")
            row("Native requests", "\(audit.nativeRequests) (\(audit.framesPerRequest.map(String.init).joined(separator: " + ")))")
            row("AVCapturePhoto callbacks", "\(audit.callbacks)", highlight: audit.callbacks != audit.requestedExposures)
            row("Callback errors", "\(audit.callbackErrors)", highlight: audit.callbackErrors > 0)
            row("Index collisions", "\(audit.indexCollisions)", highlight: audit.indexCollisions > 0)
            row("Files persisted", "\(audit.persistedFiles)")
            row("Checksums verified", "\(audit.verifiedChecksums)")
            row("Unique hashes", "\(audit.uniqueHashes)")
            row("Real frames", "\(audit.realFrames)", highlight: audit.realFrames != audit.requestedExposures)
            row("EV 0 frames", "\(audit.ev0Frames)", highlight: audit.ev0Frames != 1)
            row("Distinct exposure levels", "\(audit.distinctExposureLevels)", highlight: audit.distinctExposureLevels != audit.requestedExposures)
            row("Measured EV vs EV 0", audit.measuredRelativeEV.map { String(format: "%+.1f", $0) }.joined(separator: " "))
            if !audit.duplicateExposurePairs.isEmpty {
                row("Same exposure", audit.duplicateExposurePairs.joined(separator: "  "), highlight: true)
            }
            row("Single camera / lens", audit.singleCamera ? "YES" : "NO", highlight: !audit.singleCamera)
            if let spread = audit.lensPositionSpread {
                row("Focus lens spread", String(format: "%.4f", spread))
            }
            if let spread = audit.whiteBalanceGainSpread {
                row("WB gain spread", String(format: "%.1f%%", spread * 100))
            }
            row("Validated profile", audit.validatedProfile.devLabel, highlight: audit.validatedProfile != audit.requestedProfile)
            row("HDR-capable source", audit.supportsHDR ? "YES" : "NO", highlight: !audit.supportsHDR)
        }
    }

    private func row(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(highlight ? VE.warning : VE.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// One real exposure, opened from its own file on disk, with its metadata.
struct DevFrameViewer: View {
    let frame: CaptureFrame

    @State private var image: UIImage?
    @State private var isMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Color.black
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else if isMissing {
                            Text("File not found on disk")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(VE.warning)
                        } else {
                            ProgressView().tint(VE.textTertiary)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 8))

                Group {
                    line("sequence index", "#\(frame.sequenceIndex)")
                    line("request", frame.requestNumber.map(String.init) ?? "not recorded")
                    line("photoCount", frame.photoCountDescription)
                    line("requested EV", frame.evLabel)
                    line("actual bias", frame.actualBiasDescription)
                    line("exposure", frame.exposureDescription)
                    line("ISO", frame.isoDescription)
                    line("aperture", frame.apertureDescription)
                    line("dimensions", frame.dimensionDescription)
                    line("file size", frame.sizeDescription)
                    line("sha256", "…" + String(frame.checksum.suffix(16)))
                    line("file", CaptureBundleStore.path(for: frame))
                }
            }
            .padding(16)
        }
        .background(VE.canvas)
        .navigationTitle("EV \(frame.evLabel)")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task(id: frame.id) { await load() }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(VE.textTertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VE.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        guard let url = CaptureBundleStore.url(for: frame) else {
            isMissing = true
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            CaptureImageLoader.image(url: url, maxPixel: 2400)
        }.value
        image = loaded
        isMissing = loaded == nil
    }
}

/// Development-only luminance histogram of one exposure.
private struct LuminanceHistogram: View {
    let bins: [Double]

    var body: some View {
        GeometryReader { geometry in
            let peak = max(bins.max() ?? 1, 0.0001)
            let width = geometry.size.width / CGFloat(max(1, bins.count))
            Path { path in
                for (index, value) in bins.enumerated() {
                    let height = geometry.size.height * CGFloat(value / peak)
                    path.addRect(CGRect(
                        x: CGFloat(index) * width,
                        y: geometry.size.height - height,
                        width: max(1, width - 0.5),
                        height: height
                    ))
                }
            }
            .fill(VE.textSecondary.opacity(0.8))
        }
        .background(VE.elevated.opacity(0.6), in: .rect(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// Downsampled preview of one stored exposure. Full-resolution frames are never decoded here.
private struct FrameThumbnail: View {
    let frame: CaptureFrame

    @State private var image: UIImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    ProgressView().tint(VE.textTertiary)
                }
            }
            .clipped()
            .task(id: frame.fileName) { await load() }
    }

    private func load() async {
        guard let url = CaptureBundleStore.url(for: frame) else { return }
        let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 220,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        image = thumbnail
    }
}
