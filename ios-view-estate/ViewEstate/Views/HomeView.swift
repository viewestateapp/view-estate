import SwiftUI

/// Home dashboard. Strict hierarchy: greeting → one compact statistics card →
/// dominant copper capture action → photography-first property feed → recent captures.
struct HomeView: View {
    let onCapture: (Property?, RoomType?) -> Void

    @Environment(AppState.self) private var state
    @State private var showAccount = false
    @State private var showCredits = false
    @State private var viewerRoute: PhotoViewerRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.l) {
                    header
                    statistics
                    captureAction
                    if !state.isOnline { offlineNotice }
                    recentProperties
                    recentCaptures
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.top, VE.Space.s)
                .padding(.bottom, VE.Space.xl)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ViewEstateLogo(variant: .light, width: 112)
                        .padding(.vertical, 2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAccount = true
                    } label: {
                        Text(state.userInitials)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VE.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(VE.elevated, in: .circle)
                            .overlay(Circle().strokeBorder(VE.border, lineWidth: 1))
                    }
                    .accessibilityLabel(state.t("account.title"))
                }
            }
            .toolbarBackground(VE.canvas, for: .navigationBar)
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showCredits) { CreditsView() }
            .photoViewer($viewerRoute) { property, room in onCapture(property, room) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.t(state.greetingKey)), \(state.userFirstName)")
                .font(VE.Font.pageTitle)
                .foregroundStyle(VE.textPrimary)

            HStack(spacing: 6) {
                Image(systemName: syncIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(state.t(syncKey))
                    .font(VE.Font.caption)
            }
            .foregroundStyle(state.isOnline ? VE.textSecondary : VE.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syncIcon: String {
        switch state.syncState {
        case .synced: "checkmark.circle"
        case .pending: "clock.arrow.circlepath"
        case .uploading: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        }
    }

    private var syncKey: String {
        if !state.isOnline { return "home.sync.offline" }
        return state.syncState == .synced ? "home.sync.synced" : "home.sync.pending"
    }

    // MARK: - Statistics

    private var statistics: some View {
        HStack(spacing: 0) {
            statistic(value: "\(state.properties.count)", label: state.t("home.stat.properties"), tint: VE.textPrimary)
            divider
            statistic(value: "\(state.totalPhotos)", label: state.t("home.stat.photos"), tint: VE.textPrimary)
            divider
            Button { showCredits = true } label: {
                statistic(value: "\(state.wallet.total)", label: state.t("home.stat.credits"), tint: VE.ai)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.credits")
        }
        .padding(.vertical, VE.Space.m)
        .veCard()
    }

    private var divider: some View {
        Rectangle()
            .fill(VE.border)
            .frame(width: 1, height: 34)
    }

    private func statistic(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(VE.Font.metric)
                .foregroundStyle(tint)
            Text(label)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Primary action

    private var captureAction: some View {
        Button {
            onCapture(nil, nil)
        } label: {
            ActionLabel(title: state.t("home.cta.capture"), systemImage: "camera.fill")
        }
        .buttonStyle(CopperButtonStyle())
    }

    private var offlineNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VE.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.t("offline.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("offline.body"))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VE.Space.m)
        .veCard(surface: VE.warning.opacity(0.08))
    }

    // MARK: - Feeds

    private var recentProperties: some View {
        VStack(alignment: .leading, spacing: VE.Space.s) {
            SectionHeader(title: state.t("home.section.recentProperties"))
            ForEach(state.properties) { property in
                NavigationLink(value: property) {
                    PropertyCard(property: property)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: Property.self) { property in
            PropertyDetailView(property: property, onCapture: onCapture)
        }
    }

    private var recentCaptures: some View {
        VStack(alignment: .leading, spacing: VE.Space.s) {
            SectionHeader(title: state.t("home.section.recentCaptures"))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(state.captures.prefix(6)) { capture in
                        Button {
                            viewerRoute = PhotoViewerRoute(captureID: capture.id)
                        } label: {
                            CaptureThumbnail(capture: capture)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, VE.Space.m)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .padding(.horizontal, -VE.Space.m)
        }
    }
}
