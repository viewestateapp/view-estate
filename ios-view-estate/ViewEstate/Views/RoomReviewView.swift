import SwiftUI

/// End-of-room review, opened only when the photographer chooses "Concluir divisão".
///
/// Property, room, and every photograph of that room — newest first, in whatever state they are
/// in. Preparing photos open like any other. From here the photographer moves to the next room,
/// returns to the camera, or ends the session.
struct RoomReviewView: View {
    let property: Property
    let room: RoomType
    let onOpen: (UUID) -> Void
    let onContinue: () -> Void
    let onNextRoom: () -> Void
    let onFinish: () -> Void

    @Environment(AppState.self) private var state

    private var captures: [CaptureItem] {
        state.captures.filter { $0.propertyID == property.id && $0.room == room }
    }

    private var preparing: Int {
        captures.filter { $0.status == .preparing }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.m) {
                    header
                    if captures.isEmpty {
                        Text(state.t("review.empty"))
                            .font(VE.Font.body)
                            .foregroundStyle(VE.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else {
                        PhotoGrid(captures: captures) { onOpen($0.id) }
                    }
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.l)
            }
            .scrollIndicators(.hidden)
            actions
        }
        .background(VE.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button {
                onContinue()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(VE.surface, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.t("review.continue"))

            Spacer()

            Button(state.t("review.finish")) { onFinish() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VE.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, VE.Space.s)
        .padding(.top, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(property.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VE.copper)
                .lineLimit(1)
            Text(state.roomName(room))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(VE.textPrimary)
            HStack(spacing: 10) {
                Text(state.t("review.photos", captures.count))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                if preparing > 0 {
                    HStack(spacing: 5) {
                        PreparingDots()
                        Text(state.t("camera.queue", preparing))
                            .font(VE.Font.caption)
                            .foregroundStyle(VE.textSecondary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: preparing)
        }
        .padding(.top, VE.Space.s)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onNextRoom()
            } label: {
                ActionLabel(title: state.t("review.nextRoom"), systemImage: "door.left.hand.open")
            }
            .buttonStyle(CopperButtonStyle())

            Button {
                onContinue()
            } label: {
                ActionLabel(title: state.t("review.continue"), systemImage: "camera.fill")
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.top, VE.Space.s)
        .padding(.bottom, VE.Space.s)
        .background(VE.canvas)
    }
}
