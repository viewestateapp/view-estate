import SwiftUI

/// Brand welcome — the first surface of the product. Full-bleed architecture photography
/// under a readability scrim, the official logo with generous breathing room, a quiet
/// region selector and the copper primary action.
struct WelcomeView: View {
    var onSignIn: () -> Void = {}
    var onCreateAccount: () -> Void = {}

    @Environment(AppState.self) private var state
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                photograph(height: geometry.size.height)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(spacing: VE.Space.m) {
                        ViewEstateLogo(variant: .light, width: min(geometry.size.width * 0.66, 280))
                            .padding(.bottom, 2)

                        Text(state.t("welcome.tagline"))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(VE.textSecondary)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .padding(.bottom, VE.Space.xl)

                    regionChips
                        .padding(.bottom, VE.Space.l)

                    actions
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(VE.canvas)
        .ignoresSafeArea(edges: .top)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.1)) { appeared = true }
        }
    }

    private func photograph(height: CGFloat) -> some View {
        VE.canvas
            .overlay(alignment: .top) {
                Image("modern_villa_dusk_pool")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: height * 0.68)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        VE.canvas.opacity(0.15),
                        VE.canvas.opacity(0.55),
                        VE.canvas.opacity(0.97),
                        VE.canvas,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height * 0.72)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
    }

    private var regionChips: some View {
        HStack(spacing: VE.Space.s) {
            ForEach(Regions.all) { config in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.selectRegion(config.code)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(config.flag)
                            .font(.system(size: 15))
                        Text("\(config.countryName) · \(config.currencyCode)")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(state.regionCode == config.code ? VE.textPrimary : VE.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        Capsule()
                            .fill(state.regionCode == config.code ? VE.elevated : Color.clear)
                        Capsule()
                            .strokeBorder(
                                state.regionCode == config.code ? VE.borderStrong : VE.border,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(config.countryName), \(config.currencyCode)")
                .accessibilityAddTraits(state.regionCode == config.code ? [.isSelected] : [])
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(state.t("welcome.signIn")) {
                onSignIn()
            }
            .buttonStyle(CopperButtonStyle())

            Button(state.t("welcome.createAccount")) {
                onCreateAccount()
            }
            .buttonStyle(QuietButtonStyle())

            Button(state.t("welcome.chooseCountry")) {
                let next: RegionCode = state.regionCode == .pt ? .br : .pt
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    state.selectRegion(next)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(VE.textSecondary)
            .padding(.top, 4)
        }
    }
}

#Preview {
    WelcomeView()
        .environment(AppState())
}
