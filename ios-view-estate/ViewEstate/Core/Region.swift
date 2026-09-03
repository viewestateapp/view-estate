import Foundation

/// Founding markets. Portugal and Brazil are peers — never a translation of one another.
enum RegionCode: String, CaseIterable, Identifiable, Sendable {
    case pt = "PT"
    case br = "BR"

    var id: String { rawValue }
}

/// Centralised regional behaviour. No component may branch on the country directly —
/// everything regional is resolved from this configuration.
struct RegionConfig: Identifiable, Sendable {
    let code: RegionCode
    let countryName: String
    let localeIdentifier: String
    let currencyCode: String
    let flag: String
    let privacyFramework: String
    let timeZoneIdentifier: String
    let route: String

    var id: String { code.rawValue }

    var languageName: String {
        switch code {
        case .pt: "Português (Portugal)"
        case .br: "Português (Brasil)"
        }
    }

    /// Formats an amount using the region's own currency. Prices are never converted between regions.
    func formatted(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: localeIdentifier)
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

enum Regions {
    static let portugal = RegionConfig(
        code: .pt,
        countryName: "Portugal",
        localeIdentifier: "pt-PT",
        currencyCode: "EUR",
        flag: "🇵🇹",
        privacyFramework: "RGPD",
        timeZoneIdentifier: "Europe/Lisbon",
        route: "/pt"
    )

    static let brazil = RegionConfig(
        code: .br,
        countryName: "Brasil",
        localeIdentifier: "pt-BR",
        currencyCode: "BRL",
        flag: "🇧🇷",
        privacyFramework: "LGPD",
        timeZoneIdentifier: "America/Sao_Paulo",
        route: "/br"
    )

    static let all: [RegionConfig] = [portugal, brazil]

    static func config(for code: RegionCode) -> RegionConfig {
        switch code {
        case .pt: portugal
        case .br: brazil
        }
    }
}

/// Mocked resolver. Production priority will be:
/// organisation region → explicit selection → stored preference → device locale → IP hint → fallback.
enum RegionResolver {
    static func resolve(storedPreference: String?, deviceLocale: Locale = .current) -> RegionCode {
        if let stored = storedPreference, let code = RegionCode(rawValue: stored) {
            return code
        }
        if deviceLocale.region?.identifier == "BR" {
            return .br
        }
        return .pt
    }
}
