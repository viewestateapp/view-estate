import Foundation

/// Payment provider abstraction. View Estate is never locked to one gateway —
/// Stripe, Apple, Google or an external provider are all interchangeable channels.
protocol BillingProvider: Sendable {
    var identifier: String { get }
    func createCreditPurchase(package: CreditPackage, region: RegionCode, channel: PaymentChannel) async throws -> PaymentEvent
    func paymentStatus(reference: String) async throws -> PaymentEventType
}

/// Mock provider used in this phase. No real payment is processed anywhere.
struct MockBillingProvider: BillingProvider {
    let identifier = "mock"

    func createCreditPurchase(package: CreditPackage, region: RegionCode, channel: PaymentChannel) async throws -> PaymentEvent {
        try? await Task.sleep(for: .milliseconds(700))
        return PaymentEvent(
            id: UUID(),
            providerReference: "mock_\(package.id)_\(UUID().uuidString.prefix(8))",
            type: .paymentConfirmed,
            amount: package.prices[region] ?? 0,
            currency: Regions.config(for: region).currencyCode,
            channel: channel,
            createdAt: .now
        )
    }

    func paymentStatus(reference: String) async throws -> PaymentEventType {
        .paymentConfirmed
    }
}

/// Determines which billing actions are offered. Configurable per region, platform and origin —
/// never hardcoded to a single provider.
enum PaymentPolicyService {
    struct Context {
        let region: RegionCode
        let platform: String
        let subscriptionOrigin: PaymentChannel
    }

    static func availablePaymentOptions(_ context: Context) -> [PaymentChannel] {
        guard FeatureFlags.billingEnabled else { return [] }
        switch context.platform {
        case "ios": return [.appleIAP, .externalIOS, .web]
        case "android": return [.googlePlay, .externalAndroid, .web]
        default: return [.web]
        }
    }
}

/// Entitlements are resolved from the plan, so screens never branch on plan names.
enum EntitlementService {
    static func entitlements(for planID: PlanID) -> Set<Entitlement> {
        PlanCatalog.plan(planID).entitlements
    }

    static func has(_ entitlement: Entitlement, planID: PlanID) -> Bool {
        entitlements(for: planID).contains(entitlement)
    }
}
