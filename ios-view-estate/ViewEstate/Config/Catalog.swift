import Foundation

/// Feature flags let the product ship with capabilities disabled for phased rollout.
enum FeatureFlags {
    static let cameraNativeEnabled = false
    static let hdrProcessingEnabled = false
    static let aiToolsEnabled = true
    static let billingEnabled = false
    static let creditPurchaseEnabled = false
    static let ptMarketEnabled = true
    static let brMarketEnabled = true
    static let developerPanelEnabled = true
}

/// Plan catalogue. Entitlements — not plan names — drive what the UI unlocks.
enum PlanCatalog {
    static let all: [Plan] = [
        Plan(
            id: .individual,
            includedAICredits: 20,
            storageGB: 50,
            users: 1,
            propertyLimit: 25,
            entitlements: [.standardHDR, .objectRemoval, .declutter]
        ),
        Plan(
            id: .pro,
            includedAICredits: 50,
            storageGB: 250,
            users: 3,
            propertyLimit: nil,
            entitlements: [
                .standardHDR, .advancedAI, .objectRemoval, .declutter,
                .virtualStaging, .redecorate, .skyReplacement, .teamMembers,
            ]
        ),
        Plan(
            id: .agency,
            includedAICredits: 200,
            storageGB: 1000,
            users: 10,
            propertyLimit: nil,
            entitlements: [
                .standardHDR, .advancedAI, .objectRemoval, .declutter,
                .virtualStaging, .redecorate, .skyReplacement, .aiVideo, .teamMembers,
            ]
        ),
    ]

    static func plan(_ id: PlanID) -> Plan {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Portugal and Brazil are priced independently. Never convert one currency into the other.
enum RegionalPrices {
    static let monthly: [RegionCode: [PlanID: Decimal]] = [
        .pt: [.individual: 24.90, .pro: 59.90, .agency: 149.90],
        .br: [.individual: 89.90, .pro: 199.90, .agency: 499.90],
    ]

    static let annual: [RegionCode: [PlanID: Decimal]] = [
        .pt: [.individual: 249.00, .pro: 599.00, .agency: 1499.00],
        .br: [.individual: 899.00, .pro: 1999.00, .agency: 4999.00],
    ]

    static func monthlyPrice(_ plan: PlanID, region: RegionCode) -> Decimal {
        monthly[region]?[plan] ?? 0
    }
}

/// Credit costs are configuration, never inlined into components.
enum AIActionCatalog {
    static let all: [AIActionConfig] = [
        AIActionConfig(id: .objectRemoval, credits: 1, entitlement: .objectRemoval, systemImage: "eraser"),
        AIActionConfig(id: .personRemoval, credits: 1, entitlement: .objectRemoval, systemImage: "person.slash"),
        AIActionConfig(id: .declutter, credits: 2, entitlement: .declutter, systemImage: "wand.and.sparkles"),
        AIActionConfig(id: .virtualStaging, credits: 5, entitlement: .virtualStaging, systemImage: "sofa"),
        AIActionConfig(id: .redecoration, credits: 5, entitlement: .redecorate, systemImage: "paintpalette"),
        AIActionConfig(id: .skyReplacement, credits: 2, entitlement: .skyReplacement, systemImage: "cloud.sun"),
        AIActionConfig(id: .aiVideo, credits: 15, entitlement: .aiVideo, systemImage: "film"),
        AIActionConfig(id: .imageToVideo, credits: 10, entitlement: .aiVideo, systemImage: "photo.badge.arrow.down"),
    ]

    static func config(_ action: AIAction) -> AIActionConfig {
        all.first { $0.id == action } ?? all[0]
    }
}

/// Standard photography operations that are always included and never charge AI credits.
enum IncludedOperations {
    static let all: [String] = [
        "hdr", "exposure_merge", "alignment", "light_correction", "color_correction",
        "perspective_correction", "vertical_correction", "noise_reduction",
        "standard_sharpening", "standard_enhancement", "quality_analysis",
    ]

    static func consumesCredits(_ operation: String) -> Bool {
        !all.contains(operation)
    }
}

enum CreditPackageCatalog {
    static let all: [CreditPackage] = [
        CreditPackage(id: "pack_25", credits: 25, prices: [.pt: 19.90, .br: 69.90]),
        CreditPackage(id: "pack_50", credits: 50, prices: [.pt: 34.90, .br: 129.90]),
        CreditPackage(id: "pack_100", credits: 100, prices: [.pt: 59.90, .br: 229.90]),
    ]
}
