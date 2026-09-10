import Foundation

/// How a property exists in this build.
///
/// Development properties are fixtures used to exercise the capture flow end to end. They are
/// never part of a customer portfolio and their technical origin is only ever shown in the
/// developer panel.
enum PropertyLifecycle: String, Sendable {
    case production
    case developmentTest

    var isDevelopment: Bool { self == .developmentTest }

    /// Developer-panel label. Never rendered on a normal user surface.
    var devLabel: String {
        switch self {
        case .production: "PRODUCTION"
        case .developmentTest: "DEVELOPMENT / TEST ONLY"
        }
    }
}

/// Formats a property's 3D source can exist in. The authoring format is the source of truth;
/// every other format is a derivative generated from it.
enum SourceAssetFormat: String, Sendable, CaseIterable, Identifiable {
    case sketchupModel = "SKETCHUP_MODEL"
    case usdz = "USDZ"
    case glb = "GLB"
    case gltf = "GLTF"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sketchupModel: "SketchUp"
        case .usdz: "USDZ"
        case .glb: "GLB"
        case .gltf: "glTF"
        }
    }

    var fileExtension: String {
        switch self {
        case .sketchupModel: "skp"
        case .usdz: "usdz"
        case .glb: "glb"
        case .gltf: "gltf"
        }
    }

    /// A 3D source is a reference asset. It is never a photograph and can never feed the camera.
    var isPhotographic: Bool { false }

    /// Conversion targets the pipeline is being prepared for. Nothing is converted yet.
    static let plannedConversionTargets: [SourceAssetFormat] = [.usdz, .glb]
}

/// What a converted derivative is intended for once conversion exists. Declared now so the
/// architecture has a place to grow into; no 3D visualisation is implemented.
enum SourceAssetUse: String, Sendable, CaseIterable, Identifiable {
    case propertyPreview3D
    case developmentProperty
    case virtualStagingReference
    case cameraPositionReference
    case roomVisualization
    case marketingAsset

    var id: String { rawValue }
}

enum DerivativeState: String, Sendable {
    case notGenerated
    case planned
    case available

    var devLabel: String {
        switch self {
        case .notGenerated: "NOT_GENERATED"
        case .planned: "PLANNED"
        case .available: "AVAILABLE"
        }
    }
}

/// A converted version of an original 3D source. Like every asset in this product it points
/// back at its parent and never replaces it.
struct SourceAssetDerivative: Identifiable, Hashable, Sendable {
    let id: UUID
    let parentAssetID: UUID
    var format: SourceAssetFormat
    var state: DerivativeState
    var fileName: String?
    var intendedUses: [SourceAssetUse]
}

/// A property's original 3D source asset.
///
/// The original file is immutable: it is never overwritten, converted in place, or treated as a
/// camera photograph. Real captures always come from the camera and are stored separately.
struct PropertySourceAsset: Identifiable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    var format: SourceAssetFormat
    var isImmutable: Bool = true
    var registeredAt: Date
    var derivatives: [SourceAssetDerivative] = []

    /// A 3D source can never stand in for photographic input.
    var canFeedCamera: Bool { false }

    func derivative(_ format: SourceAssetFormat) -> SourceAssetDerivative? {
        derivatives.first { $0.format == format }
    }

    var availableDerivatives: [SourceAssetDerivative] {
        derivatives.filter { $0.state == .available }
    }

    /// Developer-panel summary such as `USDZ NOT_GENERATED · GLB NOT_GENERATED`.
    var derivativeSummary: String {
        guard !derivatives.isEmpty else { return "—" }
        return derivatives
            .map { "\($0.format.label) \($0.state.devLabel)" }
            .joined(separator: " · ")
    }

    /// Registers the conversion targets the pipeline is prepared for, all still ungenerated.
    static func registered(
        fileName: String,
        format: SourceAssetFormat,
        registeredAt: Date = .now,
        plannedTargets: [SourceAssetFormat] = SourceAssetFormat.plannedConversionTargets,
        intendedUses: [SourceAssetUse] = SourceAssetUse.allCases
    ) -> PropertySourceAsset {
        let assetID = UUID()
        return PropertySourceAsset(
            id: assetID,
            fileName: fileName,
            format: format,
            isImmutable: true,
            registeredAt: registeredAt,
            derivatives: plannedTargets.map { target in
                SourceAssetDerivative(
                    id: UUID(),
                    parentAssetID: assetID,
                    format: target,
                    state: .notGenerated,
                    fileName: nil,
                    intendedUses: intendedUses
                )
            }
        )
    }
}
