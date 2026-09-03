import Foundation

/// Who is going to photograph. Drives the plan recommendation and later, defaults.
enum ProfileType: String, Sendable, CaseIterable, Identifiable {
    case agent
    case photographer
    case agency
    case owner

    var id: String { rawValue }

    var localizationKey: String { "profile.\(rawValue)" }
    var descriptionKey: String { "profile.\(rawValue).desc" }

    var symbol: String {
        switch self {
        case .agent: "person.text.rectangle"
        case .photographer: "camera.aperture"
        case .agency: "building.2"
        case .owner: "key"
        }
    }
}

/// How many properties are photographed per month.
enum MonthlyVolume: String, Sendable, CaseIterable, Identifiable {
    case upToFive
    case upToTwenty
    case upToFifty
    case overFifty

    var id: String { rawValue }

    var localizationKey: String { "volume.\(rawValue)" }
}

/// What the user wants to achieve. More than one goal may be selected.
enum WorkGoal: String, Sendable, CaseIterable, Identifiable {
    case quality
    case speed
    case value
    case staging
    case video
    case team

    var id: String { rawValue }

    var localizationKey: String { "goal.\(rawValue)" }

    var symbol: String {
        switch self {
        case .quality: "camera.filters"
        case .speed: "bolt"
        case .value: "chart.line.uptrend.xyaxis"
        case .staging: "sofa"
        case .video: "film"
        case .team: "person.2"
        }
    }
}

/// Account details collected during sign-up. No credentials are ever persisted in this phase.
struct AccountDraft: Sendable {
    var fullName: String = ""
    var email: String = ""
    var phone: String = ""
    var company: String = ""
    var password: String = ""
    var acceptedTerms: Bool = false

    var firstName: String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }

    var initials: String {
        let parts = fullName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    var workspaceName: String {
        let trimmed = company.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let name = fullName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "View Estate" : "\(name) Workspace"
    }
}

/// Field-level validation for the sign-up form. Messages are localisation keys.
enum AccountValidation {
    static func nameError(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).count >= 3 ? nil : "error.name"
    }

    static func emailError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        let isValid = trimmed.range(of: pattern, options: .regularExpression) != nil
        return isValid ? nil : "error.email"
    }

    static func phoneError(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.count >= 9 ? nil : "error.phone"
    }

    static func passwordError(_ value: String) -> String? {
        value.count >= 8 ? nil : "error.password"
    }

    /// Mock verification: any six-digit code is accepted while no backend exists.
    static func codeError(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.count == 6 ? nil : "error.code"
    }

    static func isComplete(_ draft: AccountDraft) -> Bool {
        nameError(draft.fullName) == nil
            && emailError(draft.email) == nil
            && phoneError(draft.phone) == nil
            && passwordError(draft.password) == nil
            && draft.acceptedTerms
    }
}

/// Suggests a plan from the answers. Entitlements — not this suggestion — gate features.
enum PlanRecommender {
    static func recommend(profile: ProfileType?, volume: MonthlyVolume?, goals: Set<WorkGoal>) -> PlanID {
        if profile == .agency || volume == .overFifty || goals.contains(.team) {
            return .agency
        }
        if profile == .photographer || volume == .upToFifty || volume == .upToTwenty
            || goals.contains(.staging) || goals.contains(.video) {
            return .pro
        }
        return .individual
    }
}

/// Ordered steps of account creation.
enum OnboardingStep: Int, Sendable, CaseIterable, Identifiable {
    case profile
    case volume
    case goals
    case account
    case verification
    case done

    var id: Int { rawValue }

    /// The completion screen sits outside the progress indicator.
    static var progressSteps: Int { OnboardingStep.allCases.count - 1 }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}
