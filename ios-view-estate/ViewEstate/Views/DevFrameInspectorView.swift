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

    var body: some View {
        List {
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
            }
            .listRowBackground(VE.surface)

            Section("Exposures") {
                ForEach(manifest.orderedFrames) { frame in
                    frameRow(frame)
                }
            }
            .listRowBackground(VE.surface)
        }
        .scrollContentBackground(.hidden)
        .background(VE.canvas)
        .navigationTitle("Frame inspector")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
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
                detail(frame.fileName)
                detail("sha256 \(frame.checksum.prefix(12))… · \(frame.uploadState.devLabel)")
            }
        }
        .padding(.vertical, 4)
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
