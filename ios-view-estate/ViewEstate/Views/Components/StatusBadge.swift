import SwiftUI

/// Small user-facing status pill. Technical pipeline vocabulary never appears here.
struct StatusBadge: View {
    let status: PreparationStatus
    var compact: Bool = false

    @Environment(AppState.self) private var state

    private var tint: Color {
        switch status {
        case .ready: VE.success
        case .preparing: VE.textSecondary
        case .needsRecapture: VE.warning
        case .error: VE.danger
        case .draft: VE.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .preparing {
                PreparingDots(tint: tint)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(state.t(status.localizationKey))
                .font(VE.Font.status)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityLabel(state.t(status.localizationKey))
    }

    private var symbol: String {
        switch status {
        case .ready: "checkmark"
        case .needsRecapture: "arrow.counterclockwise"
        case .error: "exclamationmark"
        case .draft: "pencil"
        case .preparing: "ellipsis"
        }
    }
}

/// Quiet activity indicator used wherever something is preparing in the background.
struct PreparingDots: View {
    var tint: Color = VE.textSecondary
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(phase == index ? 1 : 0.3)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.25)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityHidden(true)
    }
}
