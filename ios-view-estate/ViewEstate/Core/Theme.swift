import SwiftUI

/// View Estate semantic design tokens.
/// Brand values are sampled from the official, immutable View Estate logo asset:
/// copper `#CC986B` and purple `#64368F`. Never hardcode raw colors in views.
enum VE {
    // MARK: - Brand

    /// Copper — capture, photography, primary action. Exact logo copper.
    static let copper = Color(hex: 0xCC986B)
    /// Deeper copper used for pressed states and gradients.
    static let copperDeep = Color(hex: 0xA87B52)
    /// Purple — the logo wordmark colour. Reserved for brand marks and AI fills.
    static let purple = Color(hex: 0x64368F)
    /// Lightened purple derived from the brand purple, used for AI accents on dark surfaces.
    static let ai = Color(hex: 0x9A79D4)

    // MARK: - Surfaces

    static let canvas = Color(hex: 0x16131C)
    static let surface = Color(hex: 0x221E2B)
    static let elevated = Color(hex: 0x2A2534)
    static let overlay = Color(hex: 0x0C0A11)

    // MARK: - Text

    static let textPrimary = Color(hex: 0xF3EEF9)
    static let textSecondary = Color(hex: 0xA99BC0)
    static let textTertiary = Color(hex: 0x776B8C)

    // MARK: - Lines

    static let border = Color(hex: 0xF3EEF9).opacity(0.08)
    static let borderStrong = Color(hex: 0xF3EEF9).opacity(0.14)

    // MARK: - Semantic

    static let success = Color(hex: 0x6FBF8F)
    static let warning = Color(hex: 0xE0A458)
    static let danger = Color(hex: 0xD96A6A)

    // MARK: - Radii

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 14
        static let tile: CGFloat = 12
        static let chip: CGFloat = 10
    }

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 22
        static let xl: CGFloat = 32
    }

    // MARK: - Typography roles

    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 30, weight: .bold)
        static let sectionTitle = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 16, weight: .regular)
        static let bodyMedium = SwiftUI.Font.system(size: 16, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 13, weight: .regular)
        static let status = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let metric = SwiftUI.Font.system(size: 26, weight: .semibold).monospacedDigit()
        static let mono = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// Standard elevated card treatment: subtle surface separation, restrained radius, one hairline.
    func veCard(radius: CGFloat = VE.Radius.card, surface: Color = VE.surface) -> some View {
        background(surface, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(VE.border, lineWidth: 1)
            }
    }
}
