import SwiftUI

/// Opens the photo viewer for one capture. Every entry point (camera thumbnail, room review,
/// property gallery, general gallery, home, capture summary) routes through this — always by
/// capture id, never by an HDR asset id; the viewer resolves the best available image itself.
struct PhotoViewerRoute: Identifiable, Hashable {
    let captureID: UUID
    var id: UUID { captureID }
}

extension View {
    /// Presents `PhotoViewer` full screen for the routed capture.
    func photoViewer(
        _ route: Binding<PhotoViewerRoute?>,
        onRecapture: ((Property, RoomType) -> Void)? = nil
    ) -> some View {
        fullScreenCover(item: route) { target in
            PhotoViewer(
                captureID: target.captureID,
                onClose: { route.wrappedValue = nil },
                onRecapture: onRecapture
            )
        }
    }
}

/// Image-first, near full-screen photo viewer.
///
/// - Opens instantly in every state: EV 0 while preparing, the HDR master once ready (it
///   cross-fades in place if it completes while open), the original plus recovery actions on
///   failure.
/// - Swipes through the captures of the same property and room, in shooting order.
/// - Follows the phone's physical orientation, so a landscape photograph fills the screen when
///   the phone is turned, without rotating the rest of the app.
/// - Metadata, versions and frames live one tap away in Info — never in the way of the image.
struct PhotoViewer: View {
    let onClose: () -> Void
    var onRecapture: ((Property, RoomType) -> Void)?

    @Environment(AppState.self) private var state
    @State private var orientation = PhysicalOrientationService()
    @State private var currentID: UUID
    @State private var sequence: [UUID] = []
    @State private var dragOffset: CGFloat = 0
    @State private var showInfo = false

    init(captureID: UUID, onClose: @escaping () -> Void, onRecapture: ((Property, RoomType) -> Void)? = nil) {
        self.onClose = onClose
        self.onRecapture = onRecapture
        _currentID = State(initialValue: captureID)
    }

    private var current: CaptureItem? {
        state.captures.first { $0.id == currentID }
    }

    private var pages: [UUID] {
        sequence.isEmpty ? [currentID] : sequence
    }

    private var index: Int {
        pages.firstIndex(of: currentID) ?? 0
    }

    var body: some View {
        // The outer reader respects the safe area only to measure it; the content itself runs
        // edge to edge.
        GeometryReader { outer in
            let physical = orientation.orientation
            let insets = Self.physicalInsets(outer.safeAreaInsets, orientation: physical)
            OrientedContainer(orientation: physical) {
                ZStack {
                    pager
                    chrome(insets: insets)
                }
            }
            .ignoresSafeArea()
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: physical)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            orientation.start()
            buildSequence()
        }
        .onDisappear { orientation.stop() }
        .sheet(isPresented: $showInfo) {
            PhotoDetailView(captureID: currentID, onCapture: recaptureHandler)
        }
        .sensoryFeedback(.selection, trigger: currentID)
        .accessibilityIdentifier("photo.viewer")
    }

    // MARK: - Pager

    private var pager: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element) { position, id in
                    page(id: id, isNear: abs(position - index) <= 1)
                        .frame(width: width, height: geometry.size.height)
                }
            }
            .offset(x: -CGFloat(index) * width + dragOffset)
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .contentShape(.rect)
            .gesture(swipe(width: width))
        }
        .clipped()
    }

    @ViewBuilder
    private func page(id: UUID, isNear: Bool) -> some View {
        if isNear, let capture = state.captures.first(where: { $0.id == id }) {
            CaptureImage(capture: capture, contentMode: .fit, maxPixel: ReferencePreviewService.maxPixel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(state.roomName(capture.room))
        } else {
            Color.clear
        }
    }

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let translation = value.translation.width
                let atStart = index == 0 && translation > 0
                let atEnd = index == pages.count - 1 && translation < 0
                // Rubber band at either end.
                dragOffset = (atStart || atEnd) ? translation * 0.3 : translation
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                var next = index
                if predicted < -width * 0.35 { next = min(index + 1, pages.count - 1) }
                if predicted > width * 0.35 { next = max(index - 1, 0) }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    currentID = pages[next]
                    dragOffset = 0
                }
            }
    }

    // MARK: - Chrome

    private func chrome(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, insets.top + 6)
                .padding(.horizontal, insets.leading + 12)
                .background(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: insets.top + 96)
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 0)
            if let capture = current {
                bottomPanel(capture)
                    .padding(.horizontal, insets.leading + 16)
                    .padding(.bottom, insets.bottom + 12)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            .frame(height: insets.bottom + 170)
                            .allowsHitTesting(false)
                    }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            chromeButton(systemImage: "xmark", label: state.t("common.close")) { onClose() }
                .accessibilityIdentifier("photo.viewer.close")

            Spacer()

            if let capture = current {
                chromeButton(
                    systemImage: capture.isFavorite ? "heart.fill" : "heart",
                    label: state.t("photo.favorite"),
                    tint: capture.isFavorite ? VE.copper : VE.textPrimary
                ) {
                    state.toggleFavorite(capture)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: capture.isFavorite)

                Menu {
                    Button {
                        showInfo = true
                    } label: {
                        Label(state.t("viewer.info"), systemImage: "info.circle")
                    }
                    if capture.status == .error {
                        Button {
                            state.retryPreparation(capture)
                        } label: {
                            Label(state.t("photo.action.retry"), systemImage: "arrow.clockwise")
                        }
                    }
                    if recaptureHandler != nil, capture.status != .ready {
                        Button {
                            recapture(capture)
                        } label: {
                            Label(state.t("photo.action.recapture"), systemImage: "camera")
                        }
                    }
                } label: {
                    chromeGlyph(systemImage: "ellipsis", tint: VE.textPrimary)
                }
                .accessibilityLabel(state.t("viewer.more"))
            }
        }
    }

    private func bottomPanel(_ capture: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            recovery(capture)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.roomName(capture.room))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(VE.textPrimary)
                    if let property = state.property(capture.propertyID) {
                        Text(property.title)
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    ViewerStatus(status: capture.status)
                    if pages.count > 1 {
                        Text("\(index + 1) / \(pages.count)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(VE.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }

    /// Failure never hides the photograph: the original stays visible above these actions.
    @ViewBuilder
    private func recovery(_ capture: CaptureItem) -> some View {
        switch capture.status {
        case .error:
            VStack(alignment: .leading, spacing: 10) {
                Text(state.t("photo.error.body"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VE.textPrimary)
                HStack(spacing: 10) {
                    pillButton(state.t("photo.action.retry"), systemImage: "arrow.clockwise", prominent: true) {
                        state.retryPreparation(capture)
                    }
                    if recaptureHandler != nil {
                        pillButton(state.t("photo.action.recapture"), systemImage: "camera", prominent: false) {
                            recapture(capture)
                        }
                    }
                }
            }
            .padding(14)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 16))
            .transition(.opacity)
        case .needsRecapture:
            VStack(alignment: .leading, spacing: 10) {
                Text(state.t("photo.needsRecapture.body"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VE.textPrimary)
                if recaptureHandler != nil {
                    pillButton(state.t("photo.action.recapture"), systemImage: "camera", prominent: true) {
                        recapture(capture)
                    }
                }
            }
            .padding(14)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 16))
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func pillButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color(hex: 0x1B1410) : VE.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background {
                if prominent {
                    Capsule().fill(VE.copper)
                } else {
                    Capsule().strokeBorder(VE.textPrimary.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func chromeButton(
        systemImage: String,
        label: String,
        tint: Color = VE.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chromeGlyph(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chromeGlyph(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.4), in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }

    // MARK: - Actions

    private var recaptureHandler: ((Property?, RoomType?) -> Void)? {
        guard let onRecapture else { return nil }
        return { property, room in
            guard let property, let room else { return }
            onClose()
            onRecapture(property, room)
        }
    }

    private func recapture(_ capture: CaptureItem) {
        guard let property = state.property(capture.propertyID) else { return }
        onClose()
        onRecapture?(property, capture.room)
    }

    /// The swipe sequence is fixed when the viewer opens, so it never jumps while browsing.
    private func buildSequence() {
        guard sequence.isEmpty, let capture = current else { return }
        sequence = state.reviewSequence(propertyID: capture.propertyID, room: capture.room).map(\.id)
    }

    /// Safe-area insets in the viewer's physical frame. Turned sideways, the screen's top and
    /// bottom (Dynamic Island, home indicator) become the photograph's left and right.
    static func physicalInsets(_ screen: EdgeInsets, orientation: CaptureOrientation) -> EdgeInsets {
        guard orientation.isLandscape else {
            return EdgeInsets(top: screen.top, leading: 0, bottom: screen.bottom, trailing: 0)
        }
        let side = max(screen.top, screen.bottom, 16)
        return EdgeInsets(top: 10, leading: side, bottom: 10, trailing: side)
    }
}

/// The only status words a person sees: A preparar · Pronta · Precisa de nova captura · Erro.
private struct ViewerStatus: View {
    let status: PreparationStatus

    @Environment(AppState.self) private var state

    private var tint: Color {
        switch status {
        case .ready: VE.success
        case .needsRecapture: VE.warning
        case .error: VE.danger
        case .preparing, .draft: VE.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .preparing {
                PreparingDots(tint: tint)
            } else if status == .ready {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(state.t(status.localizationKey))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.45), in: .capsule)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: status)
        .accessibilityElement(children: .combine)
    }
}
