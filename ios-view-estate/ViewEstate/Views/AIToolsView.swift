import SwiftUI

/// Advanced tooling hub. Purple identifies AI everywhere; copper never appears here.
/// Credit costs come from configuration, never from the view.
struct AIToolsView: View {
    @Environment(AppState.self) private var state

    @State private var showCredits = false
    @State private var runningAction: AIActionConfig?
    @State private var insufficient = false

    private var hasCredits: Bool { state.wallet.total > 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.m) {
                    Text(state.t("ai.subtitle"))
                        .font(VE.Font.body)
                        .foregroundStyle(VE.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    creditsSummary

                    if !hasCredits { zeroCreditsState }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(AIActionCatalog.all) { config in
                            toolCard(config)
                        }
                    }

                    includedNote
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.xl)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(state.t("ai.title"))
            .sheet(isPresented: $showCredits) { CreditsView() }
            .alert(state.t("ai.zero.title"), isPresented: $insufficient) {
                Button(state.t("ai.addCredits")) { showCredits = true }
                Button(state.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(state.t("ai.zero.body"))
            }
        }
    }

    private var creditsSummary: some View {
        Button {
            showCredits = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(VE.ai.opacity(0.16)).frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(VE.ai)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.t("credits.available", state.wallet.total))
                        .font(VE.Font.cardTitle)
                        .foregroundStyle(VE.textPrimary)
                    Text("\(state.t("credits.included", state.wallet.includedCredits)) · \(state.t("credits.purchased", state.wallet.purchasedCredits))")
                        .font(VE.Font.caption)
                        .foregroundStyle(VE.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VE.textTertiary)
            }
            .padding(VE.Space.m)
            .veCard()
        }
        .buttonStyle(.plain)
    }

    private var zeroCreditsState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.t("ai.zero.title"))
                .font(VE.Font.cardTitle)
                .foregroundStyle(VE.textPrimary)
            Text(state.t("ai.zero.body"))
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(state.t("ai.addCredits")) { showCredits = true }
                .buttonStyle(AIButtonStyle())
                .padding(.top, 4)
        }
        .padding(VE.Space.m)
        .veCard(surface: VE.ai.opacity(0.08))
    }

    private func toolCard(_ config: AIActionConfig) -> some View {
        let unlocked = state.hasEntitlement(config.entitlement)
        let affordable = state.wallet.total >= config.credits
        let enabled = unlocked && affordable && FeatureFlags.aiToolsEnabled

        return Button {
            if !affordable {
                insufficient = true
            } else if enabled {
                runningAction = config
                state.runAIAction(config)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(VE.ai.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: config.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(VE.ai)
                }

                Text(state.t(config.localizationKey))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                    .multilineTextAlignment(.leading)

                Text(state.t(config.descriptionKey))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)

                Spacer(minLength: 0)

                Text(unlocked ? costLabel(config) : state.t("ai.locked"))
                    .font(VE.Font.status)
                    .foregroundStyle(unlocked ? VE.ai : VE.textTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((unlocked ? VE.ai : VE.textTertiary).opacity(0.14), in: .capsule)
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .padding(VE.Space.m)
            .veCard()
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityLabel("\(state.t(config.localizationKey)), \(costLabel(config))")
    }

    private func costLabel(_ config: AIActionConfig) -> String {
        config.credits == 1 ? state.t("ai.cost.one") : state.t("ai.cost", config.credits)
    }

    /// Commercially relevant surface — this is where the "HDR is included" rule belongs.
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
}
