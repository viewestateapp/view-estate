import SwiftUI

/// Portfolio list. Photography leads; filters and search stay quiet chrome.
struct PropertiesView: View {
    let onCapture: (Property?, RoomType?) -> Void

    @Environment(AppState.self) private var state
    @State private var query: String = ""
    @State private var filter: PropertyFilter = .all

    enum PropertyFilter: String, CaseIterable, Identifiable {
        case all, recent, ready, preparing, favorites
        var id: String { rawValue }
        var localizationKey: String { "properties.filter.\(rawValue)" }
    }

    private var filtered: [Property] {
        var items = state.properties
        switch filter {
        case .all: break
        case .recent: items = items.sorted { $0.updatedAt > $1.updatedAt }
        case .ready: items = items.filter { $0.status == .ready }
        case .preparing: items = items.filter { $0.status == .preparing }
        case .favorites: items = items.filter(\.isFavorite)
        }
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(query)
                || $0.city.localizedStandardContains(query)
                || $0.reference.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VE.Space.m) {
                    filterRow

                    if filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(filtered) { property in
                            NavigationLink(value: property) {
                                VStack(alignment: .leading, spacing: 8) {
                                    PropertyCard(property: property, height: 190)
                                    HStack {
                                        Text(property.reference)
                                            .font(VE.Font.mono)
                                            .foregroundStyle(VE.textTertiary)
                                        Spacer()
                                        Text(property.updatedAt, format: .relative(presentation: .named))
                                            .font(VE.Font.caption)
                                            .foregroundStyle(VE.textTertiary)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, VE.Space.m)
                .padding(.bottom, VE.Space.xl)
            }
            .background(VE.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(state.t("properties.title"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: state.t("properties.search"))
            .navigationDestination(for: Property.self) { property in
                PropertyDetailView(property: property, onCapture: onCapture)
            }
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PropertyFilter.allCases) { item in
                    let isActive = filter == item
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { filter = item }
                    } label: {
                        Text(state.t(item.localizationKey))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isActive ? Color(hex: 0x1B1410) : VE.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                Capsule().fill(isActive ? VE.copper : VE.surface)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }

    private var emptyState: some View {
        VStack(spacing: VE.Space.m) {
            Image(systemName: "building.2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(VE.textTertiary)
            Text(state.t("properties.empty.title"))
                .font(VE.Font.bodyMedium)
                .foregroundStyle(VE.textSecondary)
                .multilineTextAlignment(.center)
            Button(state.t("properties.empty.cta")) {}
                .buttonStyle(QuietButtonStyle())
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
