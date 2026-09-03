import SwiftUI

/// Sign in for an existing account. Mock only — no credentials leave the device and
/// no authentication provider is contacted in this phase.
struct SignInView: View {
    let onSignedIn: () -> Void
    let onCreateAccount: () -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var state

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var showError = false

    private var canSubmit: Bool {
        AccountValidation.emailError(email) == nil && !password.isEmpty
    }

    var body: some View {
        ZStack {
            VE.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(VE.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(VE.surface, in: .circle)
                    }
                    .accessibilityLabel(state.t("common.back"))
                    Spacer()
                    ViewEstateLogo(variant: .light, width: 104)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.top, VE.Space.s)

                ScrollView {
                    VStack(alignment: .leading, spacing: VE.Space.m) {
                        OnboardingHeading(
                            title: state.t("signin.title"),
                            subtitle: state.t("signin.subtitle")
                        )
                        .padding(.bottom, VE.Space.xs)

                        OnboardingField(
                            label: state.t("field.email"),
                            text: $email,
                            errorText: state.t("error.email"),
                            keyboard: .emailAddress,
                            contentType: .emailAddress
                        )
                        OnboardingField(
                            label: state.t("field.password"),
                            text: $password,
                            contentType: .password,
                            isSecure: true
                        )

                        Button(state.t("signin.forgot")) {}
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(VE.textSecondary)

                        if showError {
                            Text(state.t("signin.error"))
                                .font(VE.Font.caption)
                                .foregroundStyle(VE.danger)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, VE.Space.m)
                    .padding(.top, VE.Space.l)
                    .padding(.bottom, VE.Space.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)

                VStack(spacing: 12) {
                    Button(state.t("signin.cta")) {
                        submit()
                    }
                    .buttonStyle(CopperButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)
                    .animation(.easeOut(duration: 0.2), value: canSubmit)

                    Button(state.t("signin.noAccount")) {
                        onCreateAccount()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VE.copper)
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.m)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard canSubmit else {
            withAnimation(.easeOut(duration: 0.2)) { showError = true }
            return
        }
        state.signIn(email: email)
        onSignedIn()
    }
}
