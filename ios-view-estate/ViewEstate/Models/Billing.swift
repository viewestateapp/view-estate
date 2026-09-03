import Foundation

// MARK: - Payment channels

/// Payment providers are only channels. View Estate remains the source of truth.
enum PaymentChannel: String, Sendable, CaseIterable, Identifiable {
    case web = "WEB"
    case appleIAP = "APPLE_IAP"
    case googlePlay = "GOOGLE_PLAY"
    case externalIOS = "EXTERNAL_IOS"
    case externalAndroid = "EXTERNAL_ANDROID"
    case manual = "MANUAL"
    case promotional = "PROMOTIONAL"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .web: "Web"
        case .appleIAP: "Apple IAP"
        case .googlePlay: "Google Play"
        case .externalIOS: "External iOS"
        case .externalAndroid: "External Android"
        case .manual: "Manual"
        case .promotional: "Promotional"
        }
    }
}

// MARK: - Plans & entitlements

enum PlanID: String, Sendable, CaseIterable, Identifiable {
    case individual, pro, agency

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .individual: "View Estate Individual"
        case .pro: "View Estate Pro"
        case .agency: "View Estate Agency"
        }
    }

    var shortName: String {
        switch self {
        case .individual: "Individual"
        case .pro: "Pro"
        case .agency: "Agency"
        }
    }
}

/// Screens ask for entitlements, never for plan names.
enum Entitlement: String, Sendable {
    case standardHDR = "standard_hdr"
    case advancedAI = "advanced_ai"
    case objectRemoval = "object_removal"
    case declutter = "declutter"
    case virtualStaging = "virtual_staging"
    case redecorate = "redecorate"
    case skyReplacement = "sky_replacement"
    case aiVideo = "ai_video"
    case teamMembers = "team_members"
}

struct Plan: Identifiable, Sendable {
    let id: PlanID
    let includedAICredits: Int
    let storageGB: Int
    let users: Int
    let propertyLimit: Int?
    let entitlements: Set<Entitlement>
}

enum SubscriptionStatus: String, Sendable, CaseIterable, Identifiable {
    case trial = "TRIAL"
    case active = "ACTIVE"
    case pastDue = "PAST_DUE"
    case cancelled = "CANCELLED"
    case expired = "EXPIRED"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trial: "Trial"
        case .active: "Active"
        case .pastDue: "Past due"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }
}

struct Subscription: Identifiable, Sendable {
    let id: UUID
    var planID: PlanID
    var region: RegionCode
    var status: SubscriptionStatus
    var paymentChannel: PaymentChannel
    var currentPeriodStart: Date
    var currentPeriodEnd: Date
    var cancelAtPeriodEnd: Bool

    var renewalDate: Date { currentPeriodEnd }
}

// MARK: - Credits

/// Included and purchased balances are stored separately and never merged internally.
struct CreditWallet: Sendable {
    private(set) var includedCredits: Int
    private(set) var purchasedCredits: Int

    var total: Int { includedCredits + purchasedCredits }

    init(includedCredits: Int, purchasedCredits: Int) {
        self.includedCredits = includedCredits
        self.purchasedCredits = purchasedCredits
    }

    /// Internal mutation surface — only `CreditService` may reach it.
    fileprivate mutating func apply(included: Int, purchased: Int) {
        includedCredits = max(0, includedCredits + included)
        purchasedCredits = max(0, purchasedCredits + purchased)
    }
}

enum CreditTransactionType: String, Sendable {
    case planMonthlyAllocation = "PLAN_MONTHLY_ALLOCATION"
    case creditPackPurchase = "CREDIT_PACK_PURCHASE"
    case aiOperation = "AI_OPERATION"
    case promotionalCredit = "PROMOTIONAL_CREDIT"
    case adminAdjustment = "ADMIN_ADJUSTMENT"
    case refund = "REFUND"
    case expiration = "EXPIRATION"
}

struct CreditTransaction: Identifiable, Sendable {
    let id: UUID
    let type: CreditTransactionType
    /// Signed amount: positive grants, negative consumption.
    let amount: Int
    let label: String
    let createdAt: Date
    /// Guards against duplicated payment events crediting a wallet twice.
    let idempotencyKey: String?
}

struct CreditPackage: Identifiable, Sendable {
    let id: String
    let credits: Int
    let prices: [RegionCode: Decimal]
}

// MARK: - AI operations

enum AIAction: String, Sendable, CaseIterable, Identifiable {
    case objectRemoval = "OBJECT_REMOVAL"
    case personRemoval = "PERSON_REMOVAL"
    case declutter = "DECLUTTER"
    case virtualStaging = "VIRTUAL_STAGING"
    case redecoration = "REDECORATION"
    case skyReplacement = "ADVANCED_SKY_REPLACEMENT"
    case aiVideo = "AI_VIDEO"
    case imageToVideo = "IMAGE_TO_VIDEO"

    var id: String { rawValue }
}

struct AIActionConfig: Identifiable, Sendable {
    let id: AIAction
    let credits: Int
    let entitlement: Entitlement
    let systemImage: String

    var localizationKey: String {
        switch id {
        case .objectRemoval: "ai.tool.objectRemoval"
        case .personRemoval: "ai.tool.personRemoval"
        case .declutter: "ai.tool.declutter"
        case .virtualStaging: "ai.tool.virtualStaging"
        case .redecoration: "ai.tool.redecoration"
        case .skyReplacement: "ai.tool.skyReplacement"
        case .aiVideo: "ai.tool.aiVideo"
        case .imageToVideo: "ai.tool.imageToVideo"
        }
    }

    var descriptionKey: String { localizationKey + ".desc" }
}

// MARK: - Payment events

enum PaymentEventType: String, Sendable {
    case paymentStarted = "PAYMENT_STARTED"
    case paymentConfirmed = "PAYMENT_CONFIRMED"
    case paymentFailed = "PAYMENT_FAILED"
    case paymentRefunded = "PAYMENT_REFUNDED"
    case subscriptionStarted = "SUBSCRIPTION_STARTED"
    case subscriptionRenewed = "SUBSCRIPTION_RENEWED"
    case subscriptionCancelled = "SUBSCRIPTION_CANCELLED"
}

struct PaymentEvent: Identifiable, Sendable {
    let id: UUID
    let providerReference: String
    let type: PaymentEventType
    let amount: Decimal
    let currency: String
    let channel: PaymentChannel
    let createdAt: Date
}

// MARK: - Wallet mutation bridge

extension CreditWallet {
    /// Namespaced access used by `CreditService` only; views can never call this.
    struct AuthorizedMutation {
        let included: Int
        let purchased: Int
    }

    mutating func authorizedApply(_ mutation: AuthorizedMutation) {
        apply(included: mutation.included, purchased: mutation.purchased)
    }
}
