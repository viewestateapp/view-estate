import SwiftUI

/// Short confirmation after a finished sequence. It reassures, shows only user-facing
/// status, and hands the next action straight back to the photographer.
/// No progress percentage, no estimated time, no technical stage names.
struct CaptureCompletedView: View {
    let capture: CaptureItem
    let property: Property
    let onContinue: () -> Void
    let onNextRoom: () -> Void
    let onClose: () -> Void

    @Environment(AppState.self) private var state
    @State private var appeared = false
    @State private var viewerRoute: PhotoViewerRoute?

    /// The live capture, so the card follows A preparar → Pronta and swaps to the HDR master.
    private var liveCapture: CaptureItem {
        state.captures.first { $0.id == capture.id } ?? capture
    }

    var body: some View {
        ZStack(alignment: .top) {
            VE.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VE.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(VE.surface, in: .circle)
                    }
                    .accessibilityLabel(state.t("common.close"))
                    Spacer()
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.top, VE.Space.s)

                Spacer(minLength: 0)

                confirmation
                    .padding(.bottom, VE.Space.l)

                capturedCard
                    .padding(.horizontal, VE.Space.m)

                if capture.isPendingSync {
                    pendingSyncHint
                        .padding(.top, VE.Space.s)
                        .padding(.horizontal, VE.Space.m)
                }

                if state.preparingCount > 0 {
                    queueHint
                        .padding(.top, VE.Space.m)
                        .padding(.horizontal, VE.Space.m)
                }

                Spacer(minLength: 0)

                actions
                    .padding(.horizontal, VE.Space.m)
                    .padding(.bottom, VE.Space.m)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
        .photoViewer($viewerRoute)
    }

    private var confirmation: some View {
        VStack(spacing: VE.Space.m) {
            ZStack {
                Circle()
                    .fill(VE.success.opacity(0.12))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder(VE.success.opacity(0.55), lineWidth: 2)
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(VE.success)
                    .scaleEffect(appeared ? 1 : 0.6)
            }

            VStack(spacing: 6) {
                Text(state.t("capture.done.title"))
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("capture.done.subtitle"))
                    .font(VE.Font.body)
                    .foregroundStyle(VE.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, VE.Space.l)
    }

    /// Tapping the photograph opens it, whatever its preparation state.
    private var capturedCard: some View {
        Button {
            viewerRoute = PhotoViewerRoute(captureID: capture.id)
        } label: {
            VStack(spacing: 0) {
                Color(VE.elevated)
                    .frame(height: 180)
                    .overlay {
                        CaptureImage(capture: liveCapture)
                            .allowsHitTesting(false)
                    }
                    .clipped()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.roomName(capture.room))
                            .font(VE.Font.cardTitle)
                            .foregroundStyle(VE.textPrimary)
                        Text(property.title)
                            .font(VE.Font.caption)
                            .foregroundStyle(VE.ai)
                    }
                    Spacer()
                    StatusBadge(status: liveCapture.status)
                }
                .padding(VE.Space.m)
            }
            .veCard()
            .clipShape(.rect(cornerRadius: VE.Radius.card))
            .contentShape(.rect(cornerRadius: VE.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture.done.photo")
    }

    private var pendingSyncHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VE.warning)
            Text(state.t("capture.done.pendingSync"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, 12)
        .veCard(radius: VE.Radius.tile, surface: VE.warning.opacity(0.08))
    }

    private var queueHint: some View {
        HStack(spacing: 10) {
            PreparingDots(tint: VE.ai)
            Text(state.t("capture.done.queue", state.preparingCount))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
            Spacer()
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, 12)
        .veCard(radius: VE.Radius.tile)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                onContinue()
            } label: {
                ActionLabel(title: state.t("capture.done.continue"), systemImage: "camera.fill")
            }
            .buttonStyle(CopperButtonStyle())

            Button {
                onNextRoom()
            } label: {
                ActionLabel(title: state.t("capture.done.nextRoom"), systemImage: "door.left.hand.open")
            }
            .buttonStyle(QuietButtonStyle())
        }
    }
}
