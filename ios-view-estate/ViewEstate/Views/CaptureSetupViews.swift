import SwiftUI

/// A pending request to open the camera: property and room may still be missing,
/// in which case the setup sheet asks for them first.
struct CaptureSetupRequest: Identifiable {
    let id = UUID()
    var property: Property?
    var suggestedRoom: RoomType?
    var currentRoom: RoomType?
}

/// A resolved request: everything the camera needs.
struct CameraRequest: Identifiable {
    let id = UUID()
    let property: Property
    let room: RoomType
}

/// The two steps that lead into the camera — choose the property, then the room.
/// Light sheets on purpose: the approved screens stay untouched.
struct CaptureSetupSheet: View {
    var initialProperty: Property?
    var suggestedRoom: RoomType?
    var currentRoom: RoomType?
    let onReady: (Property, RoomType) -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Property] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let initialProperty {
                    RoomPickerContent(
                        property: initialProperty,
                        suggested: suggestedRoom,
                        currentRoom: currentRoom
                    ) { room in
                        onReady(initialProperty, room)
                    }
                    .navigationTitle(state.t("capture.pick.room"))
                } else {
                    PropertyPickerContent { property in
                        path.append(property)
                    }
                    .navigationTitle(state.t("capture.pick.property"))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.t("common.cancel")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
            .navigationDestination(for: Property.self) { property in
                RoomPickerContent(property: property, suggested: property.rooms.first, currentRoom: nil) { room in
                    onReady(property, room)
                }
                .navigationTitle(state.t("capture.pick.room"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Step 1 — select the property to photograph.
struct PropertyPickerContent: View {
    let onSelect: (Property) -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(spacing: VE.Space.m) {
                if state.properties.isEmpty {
                    Text(state.t("properties.empty.title"))
                        .font(VE.Font.body)
                        .foregroundStyle(VE.textSecondary)
                        .padding(.vertical, 60)
                }

                ForEach(state.properties) { property in
                    Button {
                        onSelect(property)
                    } label: {
                        PropertyCard(property: property, height: 168)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VE.Space.m)
            .padding(.top, VE.Space.s)
            .padding(.bottom, VE.Space.xl)
        }
        .background(VE.canvas)
        .scrollIndicators(.hidden)
    }
}

/// Step 2 — select the room. Also used by "Próxima divisão", where the next room is
/// marked as suggested but the photographer stays in control.
struct RoomPickerContent: View {
    let property: Property
    var suggested: RoomType?
    var currentRoom: RoomType?
    let onSelect: (RoomType) -> Void

    @Environment(AppState.self) private var state

    private var rooms: [RoomType] {
        property.rooms.isEmpty ? RoomPresets.fallback : property.rooms
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VE.Space.s) {
                Text(property.title)
                    .font(VE.Font.cardTitle)
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("capture.pick.room.hint"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                    .padding(.bottom, VE.Space.xs)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(rooms) { room in
                        Button {
                            onSelect(room)
                        } label: {
                            roomTile(room)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, VE.Space.m)
            .padding(.top, VE.Space.s)
            .padding(.bottom, VE.Space.xl)
        }
        .background(VE.canvas)
        .scrollIndicators(.hidden)
    }

    private func roomTile(_ room: RoomType) -> some View {
        let isSuggested = suggested == room
        let readyCount = state.captures(for: property.id).filter { $0.room == room && $0.status == .ready }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: room.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSuggested ? VE.copper : VE.textSecondary)
                Spacer()
                if isSuggested {
                    Text(state.t("capture.pick.room.suggested"))
                        .font(VE.Font.status)
                        .foregroundStyle(VE.copper)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(VE.copper.opacity(0.16), in: .capsule)
                } else if currentRoom == room {
                    Text(state.t("capture.pick.room.current"))
                        .font(VE.Font.status)
                        .foregroundStyle(VE.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.roomName(room))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("capture.pick.room.count", readyCount))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textTertiary)
            }
        }
        .padding(VE.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .veCard(radius: VE.Radius.tile, surface: isSuggested ? VE.copper.opacity(0.1) : VE.surface)
        .overlay {
            RoundedRectangle(cornerRadius: VE.Radius.tile)
                .strokeBorder(isSuggested ? VE.copper.opacity(0.5) : .clear, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
