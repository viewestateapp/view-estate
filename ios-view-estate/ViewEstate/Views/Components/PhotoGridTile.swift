import SwiftUI

/// One photograph in a review grid. Shows the best available real image (HDR master when ready,
/// EV 0 while preparing) and only the status that matters: a small "A preparar" while
/// processing, a small warning when it needs attention, nothing once ready.
///
/// Always tappable by the caller, in every state.
struct PhotoGridTile: View {
    let capture: CaptureItem
    var showsRoom: Bool = false

    @Environment(AppState.self) private var state

    var body: some View {
        Color(VE.elevated)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CaptureImage(capture: capture)
                    .allowsHitTesting(false)
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    if showsRoom {
                        Text(state.roomName(capture.room))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(VE.textPrimary)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .lineLimit(1)
                    }
                    if capture.status == .preparing {
                        HStack(spacing: 4) {
                            PreparingDots(tint: VE.textPrimary)
                            Text(state.t("status.preparing"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(VE.textPrimary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if capture.status == .error || capture.status == .needsRecapture {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(hex: 0x1B1410))
                        .frame(width: 18, height: 18)
                        .background(capture.status == .error ? VE.danger : VE.warning, in: .circle)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if capture.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(VE.textPrimary)
                        .padding(4)
                        .background(.black.opacity(0.4), in: .circle)
                        .padding(5)
                }
            }
            .contentShape(.rect(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(state.roomName(capture.room)), \(state.t(capture.status.localizationKey))")
            .accessibilityAddTraits(.isButton)
    }
}

/// Dense photo grid shared by the room review and the galleries.
struct PhotoGrid: View {
    let captures: [CaptureItem]
    var showsRoom: Bool = false
    let onOpen: (CaptureItem) -> Void

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(captures) { capture in
                Button {
                    onOpen(capture)
                } label: {
                    PhotoGridTile(capture: capture, showsRoom: showsRoom)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photo.tile")
            }
        }
    }
}
