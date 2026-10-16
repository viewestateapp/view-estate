import SwiftUI

/// Photography-first property card: the image dominates, text sits on a gradient,
/// and the status stays a small quiet badge.
struct PropertyCard: View {
    let property: Property
    var height: CGFloat = 210

    @Environment(AppState.self) private var state

    var body: some View {
        Color(VE.elevated)
            .frame(height: height)
            .overlay {
                Image(property.coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, VE.overlay.opacity(0.35), VE.overlay.opacity(0.92)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .clipShape(.rect(cornerRadius: VE.Radius.card))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(property.title)
                        .font(VE.Font.cardTitle)
                        .foregroundStyle(VE.textPrimary)
                    Text("\(property.address), \(property.city)")
                        .font(VE.Font.caption)
                        .foregroundStyle(VE.textSecondary)
                    Text("\(state.t("properties.rooms", property.rooms.count)) · \(state.t("properties.photos", property.photoCount))")
                        .font(VE.Font.caption)
                        .foregroundStyle(VE.textTertiary)
                        .padding(.top, 2)
                }
                .padding(VE.Space.m)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                StatusBadge(status: property.status, compact: true)
                    .padding(VE.Space.m)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .combine)
    }
}

/// Square capture thumbnail with a room name and a user-facing status caption.
struct CaptureThumbnail: View {
    let capture: CaptureItem
    var size: CGFloat = 104

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color(VE.elevated)
                .frame(width: size, height: size)
                .overlay {
                    CaptureImage(capture: capture)
                        .allowsHitTesting(false)
                }
                .clipShape(.rect(cornerRadius: VE.Radius.tile))
                .overlay(alignment: .topLeading) {
                    if capture.status == .error || capture.status == .needsRecapture {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color(hex: 0x1B1410))
                            .frame(width: 18, height: 18)
                            .background(capture.status == .error ? VE.danger : VE.warning, in: .circle)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if capture.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(VE.textPrimary)
                            .padding(5)
                            .background(.black.opacity(0.35), in: .circle)
                            .padding(6)
                    }
                }

            Text(state.roomName(capture.room))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(VE.textPrimary)
                .lineLimit(1)

            HStack(spacing: 4) {
                if capture.status == .preparing {
                    PreparingDots()
                }
                Text(state.t(capture.status.localizationKey))
                    .font(VE.Font.caption)
                    .foregroundStyle(capture.status == .ready ? VE.success : VE.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
    }
}
