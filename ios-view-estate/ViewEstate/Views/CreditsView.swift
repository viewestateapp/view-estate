import SwiftUI

/// AI Credits: balance breakdown, credit packs with independent regional pricing,
/// and the traceable transaction ledger. Purchases are simulated — no payment provider
/// is connected and the wallet only changes through an authorised confirmed event.
struct CreditsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var pendingPackage: CreditPackage?
    @State private var isPurchasing = false

    private let provider: BillingProvider = MockBillingProvider()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.l) {
                    balance
                    packs
                    history
                    includedNote
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.xl)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(state.t("credits.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
            .confirmationDialog(
                state.t("credits.mockPurchase"),
                isPresented: Binding(get: { pendingPackage != nil }, set: { if !$0 { pendingPackage = nil } }),
                titleVisibility: .visible
            ) {
                if let package = pendingPackage {
                    Button(state.t("credits.mockPurchase.confirm")) {
                        Task { await simulatePurchase(package) }
                    }
                }
                Button(state.t("common.cancel"), role: .cancel) { pendingPackage = nil }
            } message: {
                Text(state.t("credits.mockPurchase.body"))
            }
        }
        .preferredColorScheme(.dark)
    }

    private var balance: some View {
        VStack(spacing: VE.Space.m) {
            VStack(spacing: 4) {
                Text("\(state.wallet.total)")
                    .font(.system(size: 52, weight: .bold).monospacedDigit())
                    .foregroundStyle(VE.ai)
                Text(state.t("credits.title"))
                    .font(VE.Font.body)
                    .foregroundStyle(VE.textSecondary)
            }
            .padding(.top, VE.Space.s)

            HStack(spacing: 0) {
                breakdown("\(state.wallet.includedCredits)", state.t("credits.included", state.wallet.includedCredits))
                Rectangle().fill(VE.border).frame(width: 1, height: 30)
                breakdown("\(state.wallet.purchasedCredits)", state.t("credits.purchased", state.wallet.purchasedCredits))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, VE.Space.m)
        .veCard()
    }

    private func breakdown(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(VE.textPrimary)
            Text(label)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var packs: some View {
        VStack(alignment: .leading, spacing: VE.Space.s) {
            SectionHeader(title: state.t("credits.packs"))

            VStack(spacing: 10) {
                ForEach(CreditPackageCatalog.all) { package in
                    Button {
                        pendingPackage = package
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.t("credits.pack", package.credits))
                                    .font(VE.Font.cardTitle)
                                    .foregroundStyle(VE.textPrimary)
                                Text(state.region.formatted(package.prices[state.regionCode] ?? 0))
                                    .font(VE.Font.caption)
                                    .foregroundStyle(VE.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(VE.ai)
                        }
                        .padding(VE.Space.m)
                        .veCard()
                    }
                    .buttonStyle(.plain)
                    .disabled(isPurchasing)
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: VE.Space.s) {
            SectionHeader(title: state.t("credits.history"))

            VStack(spacing: 0) {
                ForEach(Array(state.transactions.prefix(8).enumerated()), id: \.element.id) { index, transaction in
                    HStack(spacing: 12) {
                        Text(transaction.amount > 0 ? "+\(transaction.amount)" : "\(transaction.amount)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(transaction.amount > 0 ? VE.success : VE.textSecondary)
                            .frame(width: 42, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.t(transaction.label))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(VE.textPrimary)
                            Text(transaction.createdAt, format: .dateTime.day().month(.abbreviated))
                                .font(VE.Font.caption)
                                .foregroundStyle(VE.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, VE.Space.m)
                    .padding(.vertical, 12)

                    if index < min(state.transactions.count, 8) - 1 {
                        Rectangle().fill(VE.border).frame(height: 1).padding(.leading, 68)
                    }
                }
            }
            .veCard()
        }
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

    /// Mirrors the production flow: provider confirms → authorised event → credit service → wallet.
    private func simulatePurchase(_ package: CreditPackage) async {
        isPurchasing = true
        defer { isPurchasing = false }
        pendingPackage = nil
        do {
            let event = try await provider.createCreditPurchase(
                package: package,
                region: state.regionCode,
                channel: .web
            )
            guard event.type == .paymentConfirmed else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                state.applyConfirmedPurchase(package, event: event)
            }
        } catch {
            // A failed simulated payment never grants credits.
        }
    }
}
