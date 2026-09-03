import Foundation
import Observation
import SwiftUI

/// Single source of truth for the app shell: region, locale, mock session, portfolio,
/// wallet and connectivity. Screens read state from here and never own business rules.
@Observable
final class AppState {
    // MARK: - Session

    var isAuthenticated: Bool = false
    var userFirstName: String = "Ana"
    var organizationName: String = "Ana Ribeiro Workspace"

    // MARK: - Region & locale

    private(set) var regionCode: RegionCode

    var region: RegionConfig { Regions.config(for: regionCode) }
    var locale: String { region.localeIdentifier }

    func selectRegion(_ code: RegionCode) {
        regionCode = code
        UserDefaults.standard.set(code.rawValue, forKey: Self.regionKey)
    }

    // MARK: - Portfolio

    var properties: [Property]
    var captures: [CaptureItem]

    // MARK: - Billing & credits

    private(set) var wallet: CreditWallet
    private(set) var transactions: [CreditTransaction]
    var subscription: Subscription

    var plan: Plan { PlanCatalog.plan(subscription.planID) }

    func hasEntitlement(_ entitlement: Entitlement) -> Bool {
        EntitlementService.has(entitlement, planID: subscription.planID)
    }

    // MARK: - Connectivity

    private(set) var isOnline: Bool = true
    var syncState: SyncState = .synced

    /// Connectivity switch. Photography must stay available offline, so this only
    /// changes sync reporting — never capture availability.
    func setOnline(_ online: Bool) {
        isOnline = online
        if online {
            for index in captures.indices where captures[index].isPendingSync {
                captures[index].isPendingSync = false
            }
            syncState = pendingSyncCount > 0 ? .uploading : .synced
        } else {
            syncState = .offline
        }
    }

    /// Captures still preparing in the background — the only queue detail a user ever sees.
    var preparingCount: Int {
        captures.filter { $0.status == .preparing }.count
    }

    var pendingSyncCount: Int {
        captures.filter(\.isPendingSync).count
    }

    var totalPhotos: Int {
        properties.reduce(0) { $0 + $1.photoCount }
    }

    // MARK: - Capture session (prototype)

    /// While `capturing`, the shutter is locked so a single tap can never create two captures.
    private(set) var captureSessionState: CaptureSessionState = .idle
    private(set) var lastCaptureID: UUID?

    /// Development-only outcome of the simulated preparation.
    var captureResultMode: CaptureResultMode = .success
    /// Seconds a mock preparation takes before reaching its final state.
    var preparationSeconds: Double = 4

    var lastCapture: CaptureItem? {
        guard let lastCaptureID else { return nil }
        return captures.first { $0.id == lastCaptureID }
    }

    private var preparationTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Init

    private static let regionKey = "ve.region"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.regionKey)
        let resolved = RegionResolver.resolve(storedPreference: stored)
        regionCode = resolved
        properties = MockData.properties()
        captures = MockData.captures()
        wallet = CreditWallet(includedCredits: 32, purchasedCredits: 10)
        transactions = MockData.creditHistory()
        subscription = Subscription(
            id: UUID(),
            planID: .pro,
            region: resolved,
            status: .active,
            paymentChannel: .web,
            currentPeriodStart: Date().addingTimeInterval(-86400 * 12),
            currentPeriodEnd: Date().addingTimeInterval(86400 * 18),
            cancelAtPeriodEnd: false
        )
    }

    // MARK: - Localisation

    func t(_ key: String) -> String {
        Strings.value(key, locale: locale)
    }

    func t(_ key: String, _ count: Int) -> String {
        t(key).replacingOccurrences(of: "%d", with: "\(count)")
    }

    func t(_ key: String, _ value: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: value)
    }

    var greetingKey: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: "home.greeting.morning"
        case 12..<19: "home.greeting.afternoon"
        default: "home.greeting.evening"
        }
    }

    func roomName(_ room: RoomType) -> String {
        t(room.localizationKey)
    }

    func property(_ id: UUID) -> Property? {
        properties.first { $0.id == id }
    }

    func captures(for propertyID: UUID) -> [CaptureItem] {
        captures.filter { $0.propertyID == propertyID }
    }

    // MARK: - Capture flow (prototype)

    /// Locks the shutter for the duration of one simulated bracket sequence.
    /// Returns `false` when a sequence is already running, so repeated taps are ignored.
    func beginCaptureSequence() -> Bool {
        guard captureSessionState == .idle else { return false }
        captureSessionState = .capturing
        return true
    }

    func endCaptureSequence() {
        captureSessionState = .idle
    }

    /// Registers a finished capture sequence and starts its background preparation.
    /// The pipeline is never surfaced: the user only ever sees "A preparar" → "Pronta".
    func registerCapture(property: Property, room: RoomType, frameCount: Int) -> CaptureItem {
        // Duplicate guard: an accidental double trigger cannot create two captures.
        if let recent = captures.first,
           recent.propertyID == property.id,
           recent.room == room,
           Date().timeIntervalSince(recent.createdAt) < 1.2 {
            return recent
        }

        let createdAt = Date()
        let item = CaptureItem(
            id: UUID(),
            propertyID: property.id,
            room: room,
            image: room.placeholderImage,
            frameCount: frameCount,
            jobState: .queued,
            createdAt: createdAt,
            isFavorite: false,
            assets: [MockData.originalFrames(frameCount: frameCount, createdAt: createdAt)],
            isPendingSync: !isOnline
        )
        captures.insert(item, at: 0)
        lastCaptureID = item.id

        if let index = properties.firstIndex(where: { $0.id == property.id }) {
            properties[index].photoCount += 1
            properties[index].updatedAt = createdAt
        }

        syncState = isOnline ? .uploading : .pending
        startPreparation(for: item.id)
        return item
    }

    /// Retries a failed preparation. The immutable original is reused — never recreated.
    func retryPreparation(_ capture: CaptureItem) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].jobState = .queued
        startPreparation(for: capture.id)
    }

    /// Background preparation of one capture. Independent per capture, so photographing
    /// another room while one is still preparing is never blocked.
    private func startPreparation(for id: UUID) {
        preparationTasks[id]?.cancel()
        preparationTasks[id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.setJobState(id, .processing)

            try? await Task.sleep(for: .seconds(self.preparationSeconds))

            // Offline captures wait for connectivity, but the user is never blocked.
            while !self.isOnline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }
            self.finishPreparation(id)
        }
    }

    private func setJobState(_ id: UUID, _ jobState: ProcessingJobState) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[index].jobState = jobState
    }

    private func finishPreparation(_ id: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        let outcome = captureResultMode
        captures[index].jobState = outcome.resolvedJobState
        captures[index].isPendingSync = false

        if outcome == .success,
           let original = captures[index].originalAsset,
           !captures[index].assets.contains(where: { $0.type == .hdrMaster }) {
            // The original is appended to, never replaced.
            captures[index].assets.append(MockData.hdrMaster(parent: original, createdAt: .now))
        }

        preparationTasks[id] = nil
        if preparingCount == 0 && isOnline {
            syncState = .synced
        }
    }

    func toggleFavorite(_ capture: CaptureItem) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].isFavorite.toggle()
    }

    /// Next room of a property, used by "Próxima divisão".
    func nextRoom(after current: RoomType, in property: Property) -> RoomType {
        let rooms = property.rooms.isEmpty ? RoomPresets.fallback : property.rooms
        guard let index = rooms.firstIndex(of: current) else { return rooms[0] }
        return rooms[(index + 1) % rooms.count]
    }

    // MARK: - Credits (authorised mutations only)

    /// Simulates the authorised domain event that follows a confirmed payment.
    func applyConfirmedPurchase(_ package: CreditPackage, event: PaymentEvent) {
        let result = CreditService.applyConfirmedPurchase(
            wallet: wallet,
            package: package,
            label: "credits.tx.purchase",
            existing: transactions,
            idempotencyKey: event.providerReference
        )
        guard !result.duplicateIgnored, let transaction = result.transaction else { return }
        wallet = result.wallet
        transactions.insert(transaction, at: 0)
    }

    /// Consumes credits for an advanced AI action. Standard photography and HDR never call this.
    @discardableResult
    func runAIAction(_ config: AIActionConfig) -> Bool {
        do {
            let result = try CreditService.consume(
                wallet: wallet,
                credits: config.credits,
                label: config.localizationKey
            )
            wallet = result.wallet
            if let transaction = result.transaction {
                transactions.insert(transaction, at: 0)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Developer overrides

    func devSetCredits(included: Int, purchased: Int) {
        wallet = CreditWallet(includedCredits: included, purchasedCredits: purchased)
    }

    func devSetJobState(_ jobState: ProcessingJobState, all: Bool) {
        if all {
            for index in captures.indices {
                captures[index].jobState = jobState
            }
        } else if !captures.isEmpty {
            captures[0].jobState = jobState
        }
    }

    func devReset() {
        for task in preparationTasks.values { task.cancel() }
        preparationTasks = [:]
        properties = MockData.properties()
        captures = MockData.captures()
        transactions = MockData.creditHistory()
        wallet = CreditWallet(includedCredits: 32, purchasedCredits: 10)
        captureSessionState = .idle
        captureResultMode = .success
        lastCaptureID = nil
        isOnline = true
        syncState = .synced
    }
}

/// Rooms offered when a property has no explicit room list.
enum RoomPresets {
    static let fallback: [RoomType] = [.living, .kitchen, .bedroom, .bathroom, .exterior]
}
