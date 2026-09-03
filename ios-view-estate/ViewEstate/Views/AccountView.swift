import SwiftUI

/// Account hub: profile, plan, credits, region and preferences.
struct AccountView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var showCredits = false
    @State private var showPlan = false
    @State private var showRegion = false
    @State private var showDevPanel = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    profileRow
                }
                .listRowBackground(VE.surface)

                Section(state.t("settings.section.subscription")) {
                    Button { showPlan = true } label: {
                        row(icon: "creditcard", tint: VE.copper, title: state.t("plan.title"), value: state.plan.id.shortName)
                    }
                    Button { showCredits = true } label: {
                        row(icon: "sparkles", tint: VE.ai, title: state.t("credits.title"), value: "\(state.wallet.total)")
                    }
                }
                .listRowBackground(VE.surface)

                Section(state.t("settings.section.preferences")) {
                    Button { showRegion = true } label: {
                        row(icon: "globe", tint: VE.textSecondary, title: state.t("settings.region"), value: "\(state.region.flag) \(state.region.countryName)")
                    }
                    row(icon: "character.bubble", tint: VE.textSecondary, title: state.t("settings.language"), value: state.region.languageName)
                    row(icon: "arrow.triangle.2.circlepath", tint: VE.textSecondary, title: state.t("settings.sync"), value: state.t(state.isOnline ? "home.sync.synced" : "home.sync.offline"))
                    row(icon: "bell", tint: VE.textSecondary, title: state.t("settings.notifications"), value: "")
                }
                .listRowBackground(VE.surface)

                Section(state.t("settings.section.legal")) {
                    row(icon: "hand.raised", tint: VE.textSecondary, title: state.t("settings.privacy"), value: state.region.privacyFramework)
                    row(icon: "doc.text", tint: VE.textSecondary, title: state.t("settings.terms"), value: "")
                }
                .listRowBackground(VE.surface)

                Section(state.t("settings.section.support")) {
                    row(icon: "questionmark.circle", tint: VE.textSecondary, title: state.t("settings.help"), value: "")
                    row(icon: "info.circle", tint: VE.textSecondary, title: state.t("settings.about"), value: "1.0")
                }
                .listRowBackground(VE.surface)

                if FeatureFlags.developerPanelEnabled {
                    Section {
                        Button { showDevPanel = true } label: {
                            row(icon: "hammer", tint: VE.warning, title: state.t("settings.dev"), value: "")
                        }
                    }
                    .listRowBackground(VE.surface)
                }

                Section {
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            state.signOut()
                        }
                        dismiss()
                    } label: {
                        Text(state.t("auth.signOut"))
                            .foregroundStyle(VE.danger)
                    }
                }
                .listRowBackground(VE.surface)
            }
            .scrollContentBackground(.hidden)
            .background(VE.canvas)
            .navigationTitle(state.t("account.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
            .sheet(isPresented: $showCredits) { CreditsView() }
            .sheet(isPresented: $showPlan) { PlansView() }
            .sheet(isPresented: $showRegion) { RegionView() }
            .sheet(isPresented: $showDevPanel) { DevPanelView() }
        }
        .preferredColorScheme(.dark)
    }

    private var profileRow: some View {
        HStack(spacing: 14) {
            Text(state.userInitials)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(VE.textPrimary)
                .frame(width: 52, height: 52)
                .background(VE.elevated, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.userFullName)
                    .font(VE.Font.cardTitle)
                    .foregroundStyle(VE.textPrimary)
                Text(state.organizationName)
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                Text(state.userEmail)
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func row(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
                .font(VE.Font.body)
                .foregroundStyle(VE.textPrimary)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
            }
        }
    }
}

/// Plans with independent regional pricing — values are never converted between currencies.
struct PlansView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: VE.Space.m) {
                    ForEach(PlanCatalog.all) { plan in
                        planCard(plan)
                    }

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
                .padding(VE.Space.m)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(state.t("plan.seeAll"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func planCard(_ plan: Plan) -> some View {
        let isCurrent = plan.id == state.subscription.planID
        let price = RegionalPrices.monthlyPrice(plan.id, region: state.regionCode)

        return VStack(alignment: .leading, spacing: VE.Space.s) {
            HStack {
                Text(plan.id.displayName)
                    .font(VE.Font.cardTitle)
                    .foregroundStyle(VE.textPrimary)
                Spacer()
                if plan.id == .pro {
                    Text(state.t("plan.recommended"))
                        .font(VE.Font.status)
                        .foregroundStyle(VE.copper)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(VE.copper.opacity(0.14), in: .capsule)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(state.region.formatted(price))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("plan.perMonth"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                feature("\(plan.includedAICredits) \(state.t("plan.includedCredits"))", tint: VE.ai)
                feature("\(plan.storageGB) GB \(state.t("plan.storage"))", tint: VE.textSecondary)
                feature("\(plan.users) \(state.t("plan.users"))", tint: VE.textSecondary)
            }
            .padding(.top, 2)

            if isCurrent {
                Text(state.t("plan.current"))
                    .font(VE.Font.status)
                    .foregroundStyle(VE.success)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VE.Space.m)
        .veCard(surface: isCurrent ? VE.elevated : VE.surface)
    }

    private func feature(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
        }
    }
}

/// Region & language. Changing region switches locale, currency and legal framework.
struct RegionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: VE.Space.m) {
                Text(state.t("region.explain"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Regions.all) { config in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            state.selectRegion(config.code)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Text(config.flag)
                                .font(.system(size: 26))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.countryName)
                                    .font(VE.Font.cardTitle)
                                    .foregroundStyle(VE.textPrimary)
                                Text("\(config.languageName) · \(config.currencyCode) · \(config.privacyFramework)")
                                    .font(VE.Font.caption)
                                    .foregroundStyle(VE.textSecondary)
                            }
                            Spacer()
                            if state.regionCode == config.code {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(VE.copper)
                            }
                        }
                        .padding(VE.Space.m)
                        .veCard(surface: state.regionCode == config.code ? VE.elevated : VE.surface)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(VE.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VE.canvas)
            .navigationTitle(state.t("settings.region"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
