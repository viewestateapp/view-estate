import SwiftUI

/// Property gallery. Only user-facing statuses appear — never pipeline vocabulary.
struct GalleryView: View {
    var onCapture: ((Property?, RoomType?) -> Void)?

    @Environment(AppState.self) private var state

    @State private var roomFilter: RoomType?
    @State private var viewerRoute: PhotoViewerRoute?

    private var filtered: [CaptureItem] {
        guard let roomFilter else { return state.captures }
        return state.captures.filter { $0.room == roomFilter }
    }

    private var availableRooms: [RoomType] {
        var seen: [RoomType] = []
        for capture in state.captures where !seen.contains(capture.room) {
            seen.append(capture.room)
        }
        return seen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.m) {
                    filterRow

                    if filtered.isEmpty {
                        emptyState
                    } else {
                        PhotoGrid(captures: filtered, showsRoom: roomFilter == nil) { capture in
                            viewerRoute = PhotoViewerRoute(captureID: capture.id)
                        }
                    }
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.xl)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(state.t("gallery.title"))
            .photoViewer($viewerRoute, onRecapture: recaptureHandler)
        }
    }

    private var recaptureHandler: ((Property, RoomType) -> Void)? {
        guard let onCapture else { return nil }
        return { property, room in onCapture(property, room) }
    }

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(title: state.t("gallery.filter.all"), active: roomFilter == nil) { roomFilter = nil }
                ForEach(availableRooms) { room in
                    chip(title: state.roomName(room), active: roomFilter == room) { roomFilter = room }
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x1B1410) : VE.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background { Capsule().fill(active ? VE.copper : VE.surface) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var emptyState: some View {
        VStack(spacing: VE.Space.m) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(VE.textTertiary)
            Text(state.t("gallery.empty.title"))
                .font(VE.Font.bodyMedium)
                .foregroundStyle(VE.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

/// Original (EV 0) ↔ HDR comparison of one capture, opened by captureID. Real files only.
struct HDRCompareScreen: View {
    let captureID: UUID
    var previewCapture: CaptureItem?

    @Environment(AppState.self) private var state

    private var capture: CaptureItem? {
        previewCapture ?? state.captures.first { $0.id == captureID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VE.Space.m) {
                if let capture, let master = capture.activeMaster {
                    let usesV2 = capture.hdrMasterV2?.assetID == master.assetID
                    let crop = usesV2 ? capture.hdrMasterV2?.crop.displayInsets(exifOrientation: master.exifOrientation) : nil
                    let portrait = [5, 6, 7, 8].contains(master.exifOrientation)
                    let longSide = Double(max(master.pixelWidth, master.pixelHeight))
                    let shortSide = Double(max(1, min(master.pixelWidth, master.pixelHeight)))
                    BeforeAfterCompareView(
                        beforeURL: CaptureBundleStore.url(clientCaptureID: master.clientCaptureID, fileName: master.referenceFileName),
                        afterURL: CaptureBundleStore.url(clientCaptureID: master.clientCaptureID, fileName: master.fileName),
                        beforeCrop: crop ?? (0, 0, 0, 0)
                    )
                    .aspectRatio(portrait ? shortSide / longSide : longSide / shortSide, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: VE.Radius.card))

                    Text(state.t("photo.compare.hint"))
                        .font(VE.Font.caption)
                        .foregroundStyle(VE.textSecondary)
                }
            }
            .padding(VE.Space.m)
        }
        .background(VE.canvas)
        .navigationTitle(state.t("photo.compare"))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

/// Photo detail. Reads the live capture from state so a photo that finishes preparing
/// updates in place: A preparar → Pronta. Recovery actions appear only when needed.
struct PhotoDetailView: View {
    let captureID: UUID
    var onCapture: ((Property?, RoomType?) -> Void)?
    /// Development preview: renders a synthetic capture that is not in the portfolio.
    var previewCapture: CaptureItem?

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var capture: CaptureItem? {
        previewCapture ?? state.captures.first { $0.id == captureID }
    }

    private var property: Property? {
        guard let capture else { return nil }
        return state.property(capture.propertyID) ?? state.properties.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let capture {
                    VStack(alignment: .leading, spacing: VE.Space.m) {
                        // EV 0 while preparing, the real HDR master once it exists.
                        CaptureImage(capture: capture, contentMode: .fit, maxPixel: 2400)
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: VE.Radius.card))

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.roomName(capture.room))
                                    .font(VE.Font.cardTitle)
                                    .foregroundStyle(VE.textPrimary)
                                if let property {
                                    Text("\(property.title) · \(property.city)")
                                        .font(VE.Font.caption)
                                        .foregroundStyle(VE.textSecondary)
                                }
                            }
                            Spacer()
                            StatusBadge(status: capture.status)
                        }

                        if capture.isPendingSync {
                            pendingSync
                        }

                        recovery(for: capture)

                        metadata(capture)

                        VStack(alignment: .leading, spacing: VE.Space.s) {
                            SectionHeader(title: state.t("photo.versions"))
                            versions(capture)
                        }
                    }
                    .padding(VE.Space.m)
                }
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let capture {
                        Button {
                            state.toggleFavorite(capture)
                        } label: {
                            Image(systemName: capture.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(capture.isFavorite ? VE.copper : VE.textSecondary)
                        }
                        .accessibilityLabel(state.t("photo.favorite"))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Recovery

    @ViewBuilder
    private func recovery(for capture: CaptureItem) -> some View {
        switch capture.status {
        case .needsRecapture:
            VStack(alignment: .leading, spacing: VE.Space.s) {
                notice(
                    icon: "arrow.counterclockwise",
                    tint: VE.warning,
                    text: state.t("photo.needsRecapture.body")
                )
                Button {
                    recapture(capture)
                } label: {
                    ActionLabel(title: state.t("photo.action.recapture"), systemImage: "camera.fill")
                }
                .buttonStyle(CopperButtonStyle())
                .disabled(onCapture == nil || property == nil)
            }
        case .error:
            VStack(alignment: .leading, spacing: VE.Space.s) {
                notice(
                    icon: "exclamationmark.triangle",
                    tint: VE.danger,
                    text: state.t("photo.error.body")
                )
                Button {
                    state.retryPreparation(capture)
                } label: {
                    ActionLabel(title: state.t("photo.action.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(CopperButtonStyle())

                Button {
                    recapture(capture)
                } label: {
                    ActionLabel(title: state.t("photo.action.recapture"), systemImage: "camera.fill")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(onCapture == nil || property == nil)
            }
        default:
            EmptyView()
        }
    }

    private func recapture(_ capture: CaptureItem) {
        guard let property else { return }
        dismiss()
        onCapture?(property, capture.room)
    }

    private func notice(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(VE.Font.body)
                .foregroundStyle(VE.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(VE.Space.m)
        .veCard(surface: tint.opacity(0.08))
    }

    private var pendingSync: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VE.warning)
            Text(state.t("home.sync.pending"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, 12)
        .veCard(radius: VE.Radius.tile, surface: VE.warning.opacity(0.08))
    }

    // MARK: - Metadata

    private func metadata(_ capture: CaptureItem) -> some View {
        VStack(spacing: 0) {
            row(state.t("photo.meta.date"), capture.createdAt.formatted(date: .abbreviated, time: .shortened))
            Rectangle().fill(VE.border).frame(height: 1)
            row(state.t("photo.meta.frames"), "\(capture.frameCount)")
            Rectangle().fill(VE.border).frame(height: 1)
            row(state.t("photo.meta.creditsUsed"), "0")
        }
        .veCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(VE.Font.body)
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(VE.textPrimary)
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, 13)
    }

    /// Rows shown under "Informações e versões". A normal user sees one HDR Master (the active
    /// one); developer builds list every verified master version separately.
    private func visibleAssets(_ capture: CaptureItem) -> [AssetVersion] {
        let masters = capture.assets.filter { $0.type == .hdrMaster }
        guard !FeatureFlags.developerPanelEnabled, masters.count > 1,
              let active = capture.activeMaster else { return capture.assets }
        return capture.assets.filter { $0.type != .hdrMaster || $0.id == active.assetID }
    }

    private func versions(_ capture: CaptureItem) -> some View {
        let assets = visibleAssets(capture)
        let showsCompare = capture.hdrState == .generated && capture.activeMaster != nil
        return VStack(spacing: 0) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, version in
                versionRow(version, capture: capture)

                if index < assets.count - 1 || showsCompare {
                    Rectangle().fill(VE.border).frame(height: 1).padding(.leading, 52)
                }
            }
            if showsCompare {
                NavigationLink {
                    HDRCompareScreen(captureID: capture.id, previewCapture: previewCapture)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(VE.copper)
                            .frame(width: 24)
                        Text(state.t("photo.compare"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(VE.textPrimary)
                        Spacer()
                        Text(state.t("photo.compare.subtitle"))
                            .font(VE.Font.status)
                            .foregroundStyle(VE.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VE.textTertiary)
                    }
                    .padding(.horizontal, VE.Space.m)
                    .padding(.vertical, 13)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .veCard()
    }

    /// The real master file behind an HDR asset row, if that asset is a verified V1 or V2 master.
    private func masterRecord(for version: AssetVersion, capture: CaptureItem) -> HDRMasterRecord? {
        if let v2 = capture.hdrMasterV2, v2.assetID == version.id { return v2.displayRecord }
        if let v1 = capture.hdrMaster, v1.assetID == version.id { return v1 }
        return nil
    }

    /// In development builds the original row opens the real persisted exposure files.
    @ViewBuilder
    private func versionRow(_ version: AssetVersion, capture: CaptureItem) -> some View {
        if FeatureFlags.developerPanelEnabled, version.type == .original, let manifest = capture.manifest {
            NavigationLink {
                ExposureTruthInspectorView(manifest: manifest)
            } label: {
                versionLabel(version, inspectable: true)
            }
            .buttonStyle(.plain)
        } else if version.type == .hdrMaster, capture.hdrState == .generated,
                  let record = masterRecord(for: version, capture: capture) {
            NavigationLink {
                HDRMasterFileView(
                    title: FeatureFlags.developerPanelEnabled ? version.label : "HDR Master",
                    url: CaptureBundleStore.url(clientCaptureID: record.clientCaptureID, fileName: record.fileName),
                    lines: FeatureFlags.developerPanelEnabled
                        ? [("pipeline", record.pipelineVersion), ("dimensions", record.dimensionDescription), ("file size", record.sizeDescription)]
                        : []
                )
            } label: {
                versionLabel(version, inspectable: true, isActive: FeatureFlags.developerPanelEnabled && capture.activeMaster?.assetID == version.id)
            }
            .buttonStyle(.plain)
        } else {
            versionLabel(version, inspectable: false)
        }
    }

    private func versionLabel(_ version: AssetVersion, inspectable: Bool, isActive: Bool = false) -> some View {
                HStack(spacing: 12) {
                    Image(systemName: version.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(version.type == .aiDerivative ? VE.ai : VE.copper)
                        .frame(width: 24)
                    Text(FeatureFlags.developerPanelEnabled || version.type != .hdrMaster ? version.label : "HDR Master")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(VE.textPrimary)
                    Spacer()
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(VE.copper)
                    }
                    if version.type == .original {
                        Text(state.t("photo.original.immutable"))
                            .font(VE.Font.status)
                            .foregroundStyle(VE.textTertiary)
                    }
                    if inspectable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VE.textTertiary)
                    }
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.vertical, 13)
                .contentShape(.rect)
    }
}
