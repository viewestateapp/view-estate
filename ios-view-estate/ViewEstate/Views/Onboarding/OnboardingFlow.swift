import SwiftUI

/// Account creation. Five short questions, then a confirmation — each step is one
/// decision, the progress rail stays copper, and nothing here touches the capture flow.
struct OnboardingFlow: View {
    let onFinished: () -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var state

    @State private var step: OnboardingStep = .profile
    @State private var profile: ProfileType?
    @State private var volume: MonthlyVolume?
    @State private var goals: Set<WorkGoal> = []
    @State private var draft = AccountDraft()
    @State private var code: String = ""
    @State private var codeError: String?
    @State private var didResend = false

    private var recommendedPlan: PlanID {
        PlanRecommender.recommend(profile: profile, volume: volume, goals: goals)
    }

    var body: some View {
        ZStack {
            VE.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: VE.Space.l) {
                        content
                    }
                    .padding(.horizontal, VE.Space.m)
                    .padding(.top, VE.Space.l)
                    .padding(.bottom, VE.Space.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)

                footer
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var header: some View {
        if step != .done {
            VStack(spacing: VE.Space.s) {
                HStack {
                    Button {
                        back()
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

                    Text("\(step.rawValue + 1)/\(OnboardingStep.progressSteps)")
                        .font(VE.Font.mono)
                        .foregroundStyle(VE.textTertiary)
                        .frame(width: 36)
                }

                OnboardingProgress(step: step.rawValue + 1, total: OnboardingStep.progressSteps)
            }
            .padding(.horizontal, VE.Space.m)
            .padding(.top, VE.Space.s)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            switch step {
            case .profile, .volume:
                EmptyView()
            case .goals:
                primaryButton(title: state.t("common.continue"), enabled: !goals.isEmpty) { advance() }
            case .account:
                primaryButton(title: state.t("onboarding.account.cta"), enabled: AccountValidation.isComplete(draft)) {
                    advance()
                }
            case .verification:
                primaryButton(title: state.t("onboarding.verify.cta"), enabled: !code.isEmpty) { verify() }
                Button(state.t("onboarding.verify.resend")) {
                    withAnimation(.easeOut(duration: 0.25)) { didResend = true }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(VE.textSecondary)
                .accessibilityIdentifier("onboarding.resend")
            case .done:
                primaryButton(title: state.t("onboarding.done.cta"), enabled: true) { finish() }
            }
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.bottom, VE.Space.m)
        .padding(.top, VE.Space.xs)
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(CopperButtonStyle())
        .accessibilityIdentifier("onboarding.cta")
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: enabled)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .profile: profileStep
        case .volume: volumeStep
        case .goals: goalsStep
        case .account: accountStep
        case .verification: verificationStep
        case .done: doneStep
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            OnboardingHeading(
                title: state.t("onboarding.profile.title"),
                subtitle: state.t("onboarding.profile.subtitle")
            )
            VStack(spacing: 10) {
                ForEach(ProfileType.allCases) { item in
                    ChoiceRow(
                        title: state.t(item.localizationKey),
                        detail: state.t(item.descriptionKey),
                        symbol: item.symbol,
                        identifier: item.localizationKey,
                        isSelected: profile == item
                    ) {
                        profile = item
                        advanceAfterSelection()
                    }
                }
            }
        }
    }

    private var volumeStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            OnboardingHeading(
                title: state.t("onboarding.volume.title"),
                subtitle: state.t("onboarding.volume.subtitle")
            )
            VStack(spacing: 10) {
                ForEach(MonthlyVolume.allCases) { item in
                    ChoiceRow(
                        title: state.t(item.localizationKey),
                        identifier: item.localizationKey,
                        isSelected: volume == item
                    ) {
                        volume = item
                        advanceAfterSelection()
                    }
                }
            }
        }
    }

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            OnboardingHeading(
                title: state.t("onboarding.goals.title"),
                subtitle: state.t("onboarding.goals.subtitle")
            )
            VStack(spacing: 10) {
                ForEach(WorkGoal.allCases) { item in
                    ChoiceRow(
                        title: state.t(item.localizationKey),
                        symbol: item.symbol,
                        identifier: item.localizationKey,
                        isSelected: goals.contains(item)
                    ) {
                        if goals.contains(item) {
                            goals.remove(item)
                        } else {
                            goals.insert(item)
                        }
                    }
                }
            }
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            OnboardingHeading(
                title: state.t("onboarding.account.title"),
                subtitle: state.t("onboarding.account.subtitle")
            )

            OnboardingField(
                label: state.t("field.name"),
                text: $draft.fullName,
                errorText: errorText(AccountValidation.nameError(draft.fullName)),
                contentType: .name,
                autocapitalization: .words,
                identifier: "field.name"
            )
            OnboardingField(
                label: state.t("field.email"),
                text: $draft.email,
                errorText: errorText(AccountValidation.emailError(draft.email)),
                keyboard: .emailAddress,
                contentType: .emailAddress,
                identifier: "field.email"
            )
            OnboardingField(
                label: state.t("field.phone"),
                text: $draft.phone,
                errorText: errorText(AccountValidation.phoneError(draft.phone)),
                keyboard: .phonePad,
                contentType: .telephoneNumber,
                identifier: "field.phone"
            )
            OnboardingField(
                label: state.t("field.company"),
                text: $draft.company,
                contentType: .organizationName,
                autocapitalization: .words,
                identifier: "field.company"
            )
            OnboardingField(
                label: state.t("field.password"),
                text: $draft.password,
                errorText: errorText(AccountValidation.passwordError(draft.password)),
                contentType: .newPassword,
                isSecure: true,
                identifier: "field.password"
            )

            regionRow
            consentRow
        }
    }

    private var verificationStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.m) {
            OnboardingHeading(
                title: state.t("onboarding.verify.title"),
                subtitle: state.t("onboarding.verify.body", draft.email)
            )

            VerificationCodeField(code: $code)
                .onChange(of: code) { _, _ in codeError = nil }

            if let codeError {
                Text(state.t(codeError))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.danger)
            }

            if didResend {
                Text(state.t("onboarding.verify.resent"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.success)
                    .transition(.opacity)
            }

            Text(state.t("onboarding.verify.mock"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: VE.Space.l) {
            VStack(alignment: .leading, spacing: VE.Space.m) {
                ZStack {
                    Circle()
                        .fill(VE.success.opacity(0.12))
                        .frame(width: 84, height: 84)
                    Circle()
                        .strokeBorder(VE.success.opacity(0.55), lineWidth: 2)
                        .frame(width: 84, height: 84)
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(VE.success)
                }

                OnboardingHeading(
                    title: state.t("onboarding.done.title"),
                    subtitle: state.t("onboarding.done.body", draft.firstName)
                )
            }
            .padding(.top, VE.Space.xl)

            planCard
            includedNote
        }
    }

    // MARK: - Pieces

    private var planCard: some View {
        let plan = PlanCatalog.plan(recommendedPlan)
        let price = RegionalPrices.monthlyPrice(plan.id, region: state.regionCode)

        return VStack(alignment: .leading, spacing: VE.Space.s) {
            Text(state.t("onboarding.done.plan"))
                .font(VE.Font.status)
                .foregroundStyle(VE.copper)

            Text(plan.id.displayName)
                .font(VE.Font.cardTitle)
                .foregroundStyle(VE.textPrimary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(state.region.formatted(price))
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("plan.perMonth"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VE.ai)
                Text(state.t("credits.included", plan.includedAICredits))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
            }

            Text(state.t("onboarding.done.note"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VE.Space.m)
        .veCard()
    }

    private var includedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(VE.ai)
            Text(state.t("ai.included.note"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VE.Space.m)
        .veCard(radius: VE.Radius.tile)
    }

    private var regionRow: some View {
        HStack(spacing: 12) {
            Text(state.region.flag)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.t("settings.region"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                Text("\(state.region.countryName) · \(state.region.currencyCode) · \(state.region.privacyFramework)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VE.textPrimary)
            }
            Spacer()
            Button(state.t("common.change")) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    state.selectRegion(state.regionCode == .pt ? .br : .pt)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(VE.copper)
            .accessibilityIdentifier("onboarding.region.change")
        }
        .padding(VE.Space.m)
        .veCard(radius: VE.Radius.tile)
    }

    private var consentRow: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                draft.acceptedTerms.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: draft.acceptedTerms ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(draft.acceptedTerms ? VE.copper : VE.textTertiary)
                Text(state.t("onboarding.consent"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("onboarding.consent")
        .accessibilityAddTraits(draft.acceptedTerms ? [.isSelected] : [])
    }

    private func errorText(_ key: String?) -> String? {
        key.map { state.t($0) }
    }

    // MARK: - Navigation

    private func advanceAfterSelection() {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            advance()
        }
    }

    private func advance() {
        guard let next = step.next else { return }
        withAnimation(.easeInOut(duration: 0.28)) { step = next }
    }

    private func back() {
        guard let previous = step.previous else {
            onCancel()
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) { step = previous }
    }

    private func verify() {
        if let error = AccountValidation.codeError(code) {
            withAnimation(.easeOut(duration: 0.2)) { codeError = error }
            return
        }
        advance()
    }

    private func finish() {
        state.completeOnboarding(
            draft: draft,
            profile: profile,
            volume: volume,
            goals: goals,
            plan: recommendedPlan
        )
        onFinished()
    }
}
