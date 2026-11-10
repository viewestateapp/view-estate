import SwiftUI

/// Developer-only HDR Lab: every real file behind one capture's HDR, side by side.
/// Source exposures, EV 0, the low-resolution aligned exposures and motion mask written by
/// VE-HDR 2.0, the V1 master if any, the V2 master, and an EV 0 ↔ V2 comparison.
/// Shows files only — no processing happens in this view.
struct HDRLabView: View {
    let captureID: UUID

    @Environment(AppState.self) private var state

    private var capture: CaptureItem? {
        state.captures.first { $0.id == captureID }
    }

    var body: some View {
        ScrollView {
            if let capture {
                VStack(alignment: .leading, spacing: 18) {
                    section("Source frames (\(capture.frames.count))") {
                        grid(capture.frames.map { frame in
                            LabTile(
                                caption: "EV \(frame.evLabel)",
                                url: CaptureBundleStore.url(for: frame)
                            )
                        })
                    }

                    if let reference = capture.frames.first(where: { abs($0.requestedEV) < 0.01 }) ?? capture.frames.first {
                        section("EV 0 reference") {
                            LabTile(caption: reference.fileName, url: CaptureBundleStore.url(for: reference), maxPixel: 1600)
                        }
                    }

                    if let v2 = capture.hdrMasterV2 {
                        if !v2.labAlignedFileNames.isEmpty {
                            section("Aligned exposures (analysis resolution)") {
                                grid(v2.labAlignedFileNames.map { name in
                                    LabTile(caption: name, url: CaptureBundleStore.url(clientCaptureID: v2.clientCaptureID, fileName: name))
                                })
                            }
                        }
                        if let mask = v2.labMotionMaskFileName {
                            section(String(format: "Motion mask · %.2f%% · %@", v2.motionCoverage, v2.ghostingRisk.rawValue)) {
                                LabTile(caption: mask, url: CaptureBundleStore.url(clientCaptureID: v2.clientCaptureID, fileName: mask), maxPixel: 1200)
                            }
                        }
                    }

                    if let v1 = capture.hdrMaster {
                        section("HDR Master V1") {
                            LabTile(
                                caption: "\(v1.dimensionDescription) · \(v1.sizeDescription)",
                                url: CaptureBundleStore.url(clientCaptureID: v1.clientCaptureID, fileName: v1.previewFileName),
                                maxPixel: 1600
                            )
                        }
                    }

                    if let v2 = capture.hdrMasterV2 {
                        section("HDR Master V2 · QA \(v2.qualityResult.rawValue)") {
                            LabTile(
                                caption: "\(v2.dimensionDescription) · \(v2.sizeDescription)",
                                url: CaptureBundleStore.url(clientCaptureID: v2.clientCaptureID, fileName: v2.previewFileName),
                                maxPixel: 1600
                            )
                        }
                        section("EV 0 ↔ V2") {
                            BeforeAfterCompareView(
                                beforeURL: CaptureBundleStore.url(clientCaptureID: v2.clientCaptureID, fileName: v2.referenceFileName),
                                afterURL: CaptureBundleStore.url(clientCaptureID: v2.clientCaptureID, fileName: v2.fileName),
                                beforeCrop: v2.crop.displayInsets(exifOrientation: v2.exifOrientation),
                                afterLabel: "HDR V2"
                            )
                            .aspectRatio([5, 6, 7, 8].contains(v2.exifOrientation) ? 3 / 4 : 4 / 3, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                        }
                    } else {
                        Text("No VE-HDR 2.0 master for this capture yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                }
                .padding(16)
            }
        }
        .background(VE.canvas)
        .navigationTitle("HDR Lab")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(VE.textSecondary)
            content()
        }
    }

    private func grid(_ tiles: [LabTile]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in tile }
        }
    }
}

/// One real file, downsampled. Missing files say so explicitly.
private struct LabTile: View {
    let caption: String
    let url: URL?
    var maxPixel: Int = 400

    @State private var image: UIImage?
    @State private var isMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.black
                .aspectRatio(maxPixel > 400 ? nil : 1, contentMode: .fit)
                .frame(minHeight: maxPixel > 400 ? 180 : nil)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else if isMissing {
                        Text("missing")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(VE.warning)
                    } else {
                        ProgressView().tint(VE.textTertiary)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(VE.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: url) {
            guard let url else { isMissing = true; return }
            let size = maxPixel
            let loaded = await Task.detached(priority: .utility) {
                CaptureImageLoader.image(url: url, maxPixel: size)
            }.value
            image = loaded
            isMissing = loaded == nil
        }
    }
}
