import SwiftUI

/// Reusable Before/After comparison of two real files: "Original" (EV 0) on the left, "HDR"
/// on the right, split by a draggable handle. Never shows mock pixels: if either file cannot be
/// read, an explicit missing state is shown instead.
///
/// `beforeCrop` trims the EV 0 by the same safe crop the master received, so both sides frame
/// the scene identically (fractions of the displayed EV 0: left, top, right, bottom).
struct BeforeAfterCompareView: View {
    let beforeURL: URL?
    let afterURL: URL?
    var beforeCrop: (left: Double, top: Double, right: Double, bottom: Double) = (0, 0, 0, 0)
    var beforeLabel: String = "Original"
    var afterLabel: String = "HDR"
    var maxPixel: Int = 2400

    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var didFail = false
    @State private var split: CGFloat = 0.5
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black
                if let before, let after {
                    Image(uiImage: after)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)

                    Image(uiImage: before)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, size.width * split))
                        }

                    handle(height: size.height)
                        .position(x: size.width * split, y: size.height / 2)

                    labels
                } else if didFail {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 20, weight: .medium))
                        Text(DisplayAssetResolver.missingCode)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(VE.textTertiary)
                } else {
                    ProgressView().tint(VE.textTertiary)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        split = min(max(value.location.x / max(size.width, 1), 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .task(id: "\(beforeURL?.path ?? "-")|\(afterURL?.path ?? "-")") { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(beforeLabel) ↔ \(afterLabel)")
        .accessibilityValue("\(Int(split * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(split + 0.1, 1)
            case .decrement: split = max(split - 0.1, 0)
            @unknown default: break
            }
        }
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.4), radius: 3)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
                .scaleEffect(isDragging ? 1.12 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
        }
        .allowsHitTesting(false)
    }

    private var labels: some View {
        VStack {
            HStack {
                tag(beforeLabel)
                Spacer()
                tag(afterLabel)
            }
            Spacer()
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: .capsule)
    }

    private func load() async {
        guard let beforeURL, let afterURL else {
            didFail = true
            return
        }
        let crop = beforeCrop
        let size = maxPixel
        let images = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
            let after = CaptureImageLoader.image(url: afterURL, maxPixel: size)
            guard let full = CaptureImageLoader.cgImage(url: beforeURL, maxPixel: size) else { return (nil, after) }
            let width = Double(full.width), height = Double(full.height)
            let rect = CGRect(
                x: (crop.left * width).rounded(),
                y: (crop.top * height).rounded(),
                width: (width * (1 - crop.left - crop.right)).rounded(),
                height: (height * (1 - crop.top - crop.bottom)).rounded()
            )
            let trimmed = rect.width > 0 && rect.height > 0 ? (full.cropping(to: rect) ?? full) : full
            return (UIImage(cgImage: trimmed), after)
        }.value
        guard !Task.isCancelled else { return }
        before = images.0
        after = images.1
        didFail = images.0 == nil || images.1 == nil
    }
}

/// One verified master opened from its own file, full width. Developer and versions rows.
struct HDRMasterFileView: View {
    let title: String
    let url: URL?
    var lines: [(String, String)] = []

    @State private var image: UIImage?
    @State private var isMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Color.black
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else if isMissing {
                            Text(DisplayAssetResolver.missingCode)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VE.warning)
                        } else {
                            ProgressView().tint(VE.textTertiary)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 8))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top) {
                        Text(line.0)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(VE.textTertiary)
                            .frame(width: 130, alignment: .leading)
                        Text(line.1)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(VE.textPrimary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
        }
        .background(VE.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task(id: url) {
            guard let url else { isMissing = true; return }
            let loaded = await Task.detached(priority: .userInitiated) {
                CaptureImageLoader.image(url: url, maxPixel: 2400)
            }.value
            image = loaded
            isMissing = loaded == nil
        }
    }
}
