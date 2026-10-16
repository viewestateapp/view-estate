import SwiftUI

/// Pushed detail screen — the tab bar is hidden so the bottom capture action owns the edge.
struct PropertyDetailView: View {
    let property: Property
    let onCapture: (Property?, RoomType?) -> Void

    @Environment(AppState.self) private var state
    @State private var viewerRoute: PhotoViewerRoute?

    private var captures: [CaptureItem] {
        state.captures(for: property.id)
    }

    /// Lineage of the most recent capture of this property: original first, derivatives after.
    private var lineageAssets: [AssetVersion] {
        captures.first?.assets ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VE.Space.l) {
                hero
                overview
                photos
                rooms
                lineage
            }
            .padding(.bottom, 120)
        }
        .photoViewer($viewerRoute) { property, room in onCapture(property, room) }
        .background(VE.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle(property.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            Button {
                onCapture(property, nil)
            } label: {
                ActionLabel(title: state.t("properties.detail.capture"), systemImage: "camera.fill")
            }
            .buttonStyle(CopperButtonStyle())
            .padding(.horizontal, VE.Space.m)
            .padding(.bottom, VE.Space.s)
            .background(.ultraThinMaterial)
        }
    }

    private var hero: some View {
        Color(VE.elevated)
            .frame(height: 260)
            .overlay {
                Image(property.coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, VE.canvas.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(property.reference)
                        .font(VE.Font.mono)
                        .foregroundStyle(VE.copper)
                    Text(property.title)
                        .font(VE.Font.pageTitle)
                        .foregroundStyle(VE.textPrimary)
                    Text("\(property.address), \(property.city)")
                        .font(VE.Font.body)
                        .foregroundStyle(VE.textSecondary)
                }
                .padding(VE.Space.m)
            }
            .overlay(alignment: .topTrailing) {
                StatusBadge(status: property.status)
                    .padding(VE.Space.m)
            }
    }

    private var overview: some View {
        HStack(spacing: 0) {
            metric("\(property.rooms.count)", state.t("properties.detail.rooms"))
            Rectangle().fill(VE.border).frame(width: 1, height: 32)
            metric("\(property.photoCount)", state.t("properties.detail.photos"))
            Rectangle().fill(VE.border).frame(width: 1, height: 32)
            metric("\(captures.filter { $0.status == .ready }.count)", state.t("status.ready"))
        }
        .padding(.vertical, VE.Space.m)
        .veCard()
        .padding(.horizontal, VE.Space.m)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(VE.textPrimary)
            Text(label)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var rooms: some View {
        VStack(alignment: .leading, spacing: VE.Space.s) {
            SectionHeader(title: state.t("properties.detail.rooms"))
                .padding(.horizontal, VE.Space.m)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(property.rooms) { room in
                        Button {
                            onCapture(property, room)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "camera")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(state.roomName(room))
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(VE.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(VE.surface, in: .capsule)
                            .overlay(Capsule().strokeBorder(VE.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, VE.Space.m)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The property's main review surface: every photograph, grouped by room, newest first.
    /// Each tile opens the viewer in any state.
    private var photos: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            SectionHeader(title: state.t("properties.detail.gallery"))
                .padding(.horizontal, VE.Space.m)

            if captures.isEmpty {
                Text(state.t("gallery.empty.title"))
                    .font(VE.Font.body)
                    .foregroundStyle(VE.textSecondary)
                    .padding(.horizontal, VE.Space.m)
                    .padding(.vertical, 30)
            } else {
                ForEach(roomsWithPhotos) { room in
                    let roomCaptures = captures.filter { $0.room == room }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(state.roomName(room))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(VE.textPrimary)
                            Text("\(roomCaptures.count)")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(VE.textTertiary)
                        }
                        PhotoGrid(captures: roomCaptures) { capture in
                            viewerRoute = PhotoViewerRoute(captureID: capture.id)
                        }
                    }
                    .padding(.horizontal, VE.Space.m)
                }
            }
        }
    }

    /// Rooms in the order their most recent photo was taken.
    private var roomsWithPhotos: [RoomType] {
        var seen: [RoomType] = []
        for capture in captures where !seen.contains(capture.room) {
            seen.append(capture.room)
        }
        return seen
    }

    @ViewBuilder
    private var lineage: some View {
        if !lineageAssets.isEmpty {
            VStack(alignment: .leading, spacing: VE.Space.s) {
                SectionHeader(title: state.t("photo.versions"))
                    .padding(.horizontal, VE.Space.m)

                VStack(spacing: 0) {
                    ForEach(Array(lineageAssets.enumerated()), id: \.element.id) { index, version in
                        HStack(spacing: 12) {
                            Image(systemName: version.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(version.type == .aiDerivative ? VE.ai : VE.copper)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.label)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(VE.textPrimary)
                                Text(state.t(version.type == .original ? "photo.original.immutable" : "photo.derivative"))
                                    .font(VE.Font.caption)
                                    .foregroundStyle(VE.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, VE.Space.m)

                        if index < lineageAssets.count - 1 {
                            Rectangle().fill(VE.border).frame(height: 1).padding(.leading, 54)
                        }
                    }
                }
                .veCard()
                .padding(.horizontal, VE.Space.m)
            }
        }
    }
}
