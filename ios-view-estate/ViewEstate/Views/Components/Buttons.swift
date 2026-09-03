import SwiftUI

/// Dominant copper action. Copper is reserved for capture, photography and primary actions.
struct CopperButtonStyle: ButtonStyle {
    var icon: String?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(hex: 0x1B1410))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .fill(
                        LinearGradient(
                            colors: [VE.copper, VE.copperDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Quiet bordered action used for secondary choices.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = VE.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .strokeBorder(VE.borderStrong, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Purple action reserved for AI and intelligent tooling.
struct AIButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(VE.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(VE.ai.opacity(configuration.isPressed ? 0.5 : 0.38), in: .rect(cornerRadius: VE.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .strokeBorder(VE.ai.opacity(0.55), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Label with a leading glyph, used inside primary buttons.
struct ActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
        }
    }
}

/// Section heading shared by every scrolling surface.
struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(VE.Font.sectionTitle)
                .foregroundStyle(VE.textPrimary)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VE.ai)
            }
        }
    }
}
