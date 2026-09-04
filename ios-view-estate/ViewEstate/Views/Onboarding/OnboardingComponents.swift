import SwiftUI

/// Thin copper progress rail used at the top of every onboarding step.
struct OnboardingProgress: View {
    let step: Int
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(VE.borderStrong)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [VE.copperDeep, VE.copper],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: step)
        .accessibilityHidden(true)
    }

    private var progress: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0.08, CGFloat(step) / CGFloat(total)))
    }
}

/// Question heading shared by every step.
struct OnboardingHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(VE.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(VE.Font.body)
                    .foregroundStyle(VE.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One selectable answer. Copper marks the choice; the row keeps a calm, instrument-like feel.
struct ChoiceRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    var identifier: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { action() }
        } label: {
            HStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? VE.copper : VE.textSecondary)
                        .frame(width: 26)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VE.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(VE.Font.caption)
                            .foregroundStyle(VE.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? VE.copper : VE.borderStrong, lineWidth: isSelected ? 6 : 1)
                        .frame(width: 22, height: 22)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
            }
            .padding(VE.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .fill(isSelected ? VE.copper.opacity(0.1) : VE.surface)
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .strokeBorder(isSelected ? VE.copper.opacity(0.55) : VE.border, lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(identifier ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Subtle press feedback for large tap targets.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Form field with inline validation. Errors only appear once a field has been visited.
struct OnboardingField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var errorText: String?
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var isSecure: Bool = false
    var autocapitalization: TextInputAutocapitalization = .never
    var identifier: String?

    @FocusState private var isFocused: Bool
    @State private var wasEdited = false

    private var showsError: Bool {
        errorText != nil && wasEdited && !isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(VE.Font.body)
            .foregroundStyle(VE.textPrimary)
            .tint(VE.copper)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled()
            .focused($isFocused)
            .accessibilityIdentifier(identifier ?? label)
            .padding(.horizontal, VE.Space.m)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .fill(VE.surface)
                RoundedRectangle(cornerRadius: VE.Radius.control)
                    .strokeBorder(
                        showsError ? VE.danger.opacity(0.7) : (isFocused ? VE.copper.opacity(0.6) : VE.border),
                        lineWidth: 1
                    )
            }
            .onChange(of: text) { _, _ in wasEdited = true }
            .animation(.easeOut(duration: 0.2), value: isFocused)

            if showsError, let errorText {
                Text(errorText)
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.danger)
                    .transition(.opacity)
            }
        }
    }
}

/// Six-digit verification entry. Digits are rendered as separate cells over a hidden field.
struct VerificationCodeField: View {
    @Binding var code: String
    var length: Int = 6

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .accessibilityIdentifier("onboarding.code")
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    code = String(digits.prefix(length))
                    // The keypad has no return key — step aside once the code is complete
                    // so the confirmation action is never left under the keyboard.
                    if code.count == length { isFocused = false }
                }

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    cell(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func cell(at index: Int) -> some View {
        let characters = Array(code)
        let value = index < characters.count ? String(characters[index]) : ""
        let isActive = index == characters.count && isFocused

        return Text(value)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundStyle(VE.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: VE.Radius.tile)
                    .fill(VE.surface)
                RoundedRectangle(cornerRadius: VE.Radius.tile)
                    .strokeBorder(isActive ? VE.copper.opacity(0.7) : VE.border, lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.18), value: isActive)
    }
}
