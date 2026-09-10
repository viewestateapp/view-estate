import Foundation

/// Development-only fixtures used to exercise the real flows end to end.
///
/// These properties exist so the native camera can be tested against a known space. They are
/// marked `developmentTest`, and their technical origin — including any 3D source asset — is only
/// ever visible inside the developer panel.
enum DevFixtures {
    static let sergioResidenceID = UUID()

    /// The reference property for the native camera spike.
    ///
    /// The space is documented by a SketchUp model (`sergio.skp`). That file is a reference asset:
    /// it is registered as immutable, never converted in place, and never used as photographic
    /// input. Every capture on this property still comes from the real camera.
    static func sergioResidence() -> Property {
        Property(
            id: sergioResidenceID,
            reference: "VE-DEV-001",
            title: "Residência Sergio",
            type: .house,
            address: "Modelo de referência",
            city: "Desenvolvimento",
            countryCode: "PT",
            coverImage: "modern_villa_dusk_pool",
            rooms: [.living, .kitchen, .dining, .bedroom, .bathroom, .office, .garage, .exterior],
            photoCount: 0,
            status: .draft,
            updatedAt: Date(),
            isFavorite: false,
            lifecycle: .developmentTest,
            sourceAsset: PropertySourceAsset.registered(
                fileName: "sergio.skp",
                format: .sketchupModel
            )
        )
    }
}
