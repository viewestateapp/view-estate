import Foundation

/// Mock repository for this foundation phase. No production backend is connected.
enum MockData {
    static let apartmentID = UUID()
    static let villaID = UUID()
    static let loftID = UUID()

    static func properties() -> [Property] {
        [
            Property(
                id: apartmentID,
                reference: "VE-0231",
                title: "Apartamento T3",
                type: .apartment,
                address: "Av. da Liberdade",
                city: "Lisboa",
                countryCode: "PT",
                coverImage: "lisbon_apartment_living_room",
                rooms: [.living, .kitchen, .bedroom, .bathroom, .balcony, .office],
                photoCount: 48,
                status: .ready,
                updatedAt: Date().addingTimeInterval(-3600 * 5),
                isFavorite: true
            ),
            Property(
                id: villaID,
                reference: "VE-0230",
                title: "Residência Martins",
                type: .house,
                address: "Quinta da Marinha",
                city: "Cascais",
                countryCode: "PT",
                coverImage: "white_villa_pool_twilight",
                rooms: [.living, .kitchen, .bedroom, .bathroom, .exterior],
                photoCount: 72,
                status: .preparing,
                updatedAt: Date().addingTimeInterval(-3600 * 26),
                isFavorite: false
            ),
            Property(
                id: loftID,
                reference: "VE-0228",
                title: "Loft da Prata",
                type: .apartment,
                address: "Rua da Prata",
                city: "Porto",
                countryCode: "PT",
                coverImage: "urban_loft_interior",
                rooms: [.living, .kitchen, .bedroom, .bathroom],
                photoCount: 31,
                status: .needsRecapture,
                updatedAt: Date().addingTimeInterval(-3600 * 74),
                isFavorite: false
            ),
        ]
    }

    static func captures() -> [CaptureItem] {
        [
            capture(property: villaID, room: .living, image: "modern_living_room", jobState: .processing, ageSeconds: 600),
            capture(property: apartmentID, room: .kitchen, image: "modern_kitchen_interior", jobState: .ready, ageSeconds: 5400, favorite: true),
            capture(property: apartmentID, room: .bedroom, image: "modern_bedroom_interior", jobState: .ready, ageSeconds: 9000, frameCount: 7),
            capture(property: villaID, room: .exterior, image: "villa_pool_terrace", jobState: .queued, ageSeconds: 1200),
            capture(property: loftID, room: .living, image: "urban_loft_interior", jobState: .ready, ageSeconds: 172_800),
            capture(property: apartmentID, room: .living, image: "lisbon_apartment_living_room", jobState: .ready, ageSeconds: 190_000, favorite: true),
        ]
    }

    private static func capture(
        property: UUID,
        room: RoomType,
        image: String,
        jobState: ProcessingJobState,
        ageSeconds: TimeInterval,
        frameCount: Int = 9,
        favorite: Bool = false
    ) -> CaptureItem {
        let createdAt = Date().addingTimeInterval(-ageSeconds)
        return CaptureItem(
            id: UUID(),
            propertyID: property,
            room: room,
            image: image,
            frameCount: frameCount,
            jobState: jobState,
            createdAt: createdAt,
            isFavorite: favorite,
            assets: lineage(frameCount: frameCount, createdAt: createdAt, includeMaster: jobState == .ready)
        )
    }

    /// Capture → immutable original frames → HDR master. The original is never replaced.
    static func lineage(frameCount: Int, createdAt: Date, includeMaster: Bool) -> [AssetVersion] {
        let original = originalFrames(frameCount: frameCount, createdAt: createdAt)
        guard includeMaster else { return [original] }
        return [original, hdrMaster(parent: original, createdAt: createdAt.addingTimeInterval(6))]
    }

    static func originalFrames(frameCount: Int, createdAt: Date) -> AssetVersion {
        AssetVersion(
            id: UUID(),
            parentAssetID: nil,
            type: .original,
            label: "Original · \(frameCount)",
            versionNumber: 1,
            createdAt: createdAt
        )
    }

    static func hdrMaster(parent: AssetVersion, createdAt: Date) -> AssetVersion {
        AssetVersion(
            id: UUID(),
            parentAssetID: parent.id,
            type: .hdrMaster,
            label: "HDR Master",
            versionNumber: 1,
            createdAt: createdAt
        )
    }

    static func creditHistory() -> [CreditTransaction] {
        [
            CreditTransaction(id: UUID(), type: .planMonthlyAllocation, amount: 50, label: "credits.tx.allocation", createdAt: Date().addingTimeInterval(-86400 * 12), idempotencyKey: "alloc_2026_09"),
            CreditTransaction(id: UUID(), type: .creditPackPurchase, amount: 25, label: "credits.tx.purchase", createdAt: Date().addingTimeInterval(-86400 * 8), idempotencyKey: "pay_mock_A31F"),
            CreditTransaction(id: UUID(), type: .aiOperation, amount: -5, label: "ai.tool.virtualStaging", createdAt: Date().addingTimeInterval(-86400 * 6), idempotencyKey: nil),
            CreditTransaction(id: UUID(), type: .aiOperation, amount: -1, label: "ai.tool.objectRemoval", createdAt: Date().addingTimeInterval(-86400 * 4), idempotencyKey: nil),
            CreditTransaction(id: UUID(), type: .aiOperation, amount: -2, label: "ai.tool.declutter", createdAt: Date().addingTimeInterval(-86400 * 2), idempotencyKey: nil),
        ]
    }

    /// Sample lineage used by preview surfaces only.
    static func assetLineage() -> [AssetVersion] {
        let original = originalFrames(frameCount: 9, createdAt: Date().addingTimeInterval(-8000))
        let master = hdrMaster(parent: original, createdAt: Date().addingTimeInterval(-7600))
        let staged = AssetVersion(id: UUID(), parentAssetID: master.id, type: .aiDerivative, label: "Virtual Staging #1", versionNumber: 1, createdAt: Date().addingTimeInterval(-5000))
        return [original, master, staged]
    }
}
