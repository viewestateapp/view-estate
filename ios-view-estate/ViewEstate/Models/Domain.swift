import Foundation

// MARK: - User-facing preparation status

/// The ONLY statuses a normal user ever sees. The internal pipeline stays invisible.
enum PreparationStatus: String, Sendable, CaseIterable {
    case preparing
    case ready
    case needsRecapture
    case error
    case draft

    var localizationKey: String {
        switch self {
        case .preparing: "status.preparing"
        case .ready: "status.ready"
        case .needsRecapture: "status.needsRecapture"
        case .error: "status.error"
        case .draft: "status.draft"
        }
    }
}

/// Internal processing state model. Never rendered directly — always mapped to `PreparationStatus`.
enum ProcessingJobState: String, Sendable {
    case queued
    case processing
    case ready
    case needsReview
    case failed

    var userFacing: PreparationStatus {
        switch self {
        case .queued, .processing: .preparing
        case .ready: .ready
        case .needsReview: .needsRecapture
        case .failed: .error
        }
    }
}

/// Simulated outcome of a preparation job. Development-only switch used to validate
/// every user-facing state before real processing exists.
enum CaptureResultMode: String, Sendable, CaseIterable, Identifiable {
    case success
    case needsRecapture
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .success: "Success"
        case .needsRecapture: "Needs Recapture"
        case .error: "Error"
        }
    }

    var resolvedJobState: ProcessingJobState {
        switch self {
        case .success: .ready
        case .needsRecapture: .needsReview
        case .error: .failed
        }
    }
}

/// Live shutter state. While `capturing`, no new sequence may start.
enum CaptureSessionState: String, Sendable {
    case idle
    case capturing
}

/// One individual shutter action.
///
/// Every tap of the shutter mints a brand new `id` (the client capture id). All nine
/// simulated exposure frames belong to that attempt, and any duplicated completion event
/// carrying the same id resolves to the same `CaptureItem`. A new shutter action always
/// mints a new attempt, so two legitimate photographs of the same room in the same second
/// still produce two distinct captures. Idempotency is never inferred from a time window.
struct CaptureAttempt: Identifiable, Hashable, Sendable {
    let id: UUID
    let propertyID: UUID
    let room: RoomType
    let startedAt: Date

    init(propertyID: UUID, room: RoomType, startedAt: Date = .now) {
        self.id = UUID()
        self.propertyID = propertyID
        self.room = room
        self.startedAt = startedAt
    }

    var shortID: String { String(id.uuidString.prefix(8)) }
}

// MARK: - Rooms

enum RoomType: String, Sendable, CaseIterable, Identifiable {
    case living, kitchen, bedroom, bathroom, dining, office, balcony, exterior, garage, other

    var id: String { rawValue }

    var localizationKey: String { "room.\(rawValue)" }

    var placeholderImage: String {
        switch self {
        case .kitchen: "modern_kitchen_interior"
        case .bedroom: "modern_bedroom_interior"
        case .exterior, .balcony, .garage: "villa_pool_terrace"
        default: "modern_living_room"
        }
    }

    var symbol: String {
        switch self {
        case .living: "sofa"
        case .kitchen: "cooktop"
        case .bedroom: "bed.double"
        case .bathroom: "shower"
        case .dining: "fork.knife"
        case .office: "desktopcomputer"
        case .balcony: "sun.horizon"
        case .exterior: "tree"
        case .garage: "car"
        case .other: "square.dashed"
        }
    }
}

// MARK: - Property

enum PropertyType: String, Sendable, CaseIterable {
    case apartment, house, land, commercial, development, office, warehouse, other
}

struct Property: Identifiable, Hashable, Sendable {
    let id: UUID
    var reference: String
    var title: String
    var type: PropertyType
    var address: String
    var city: String
    var countryCode: String
    var coverImage: String
    var rooms: [RoomType]
    var photoCount: Int
    var status: PreparationStatus
    var updatedAt: Date
    var isFavorite: Bool
    /// Production portfolio or a development fixture. Never shown to a normal user.
    var lifecycle: PropertyLifecycle = .production
    /// Reference 3D model this property was modelled from, when one exists. A source asset is
    /// documentation for the space — immutable, and never photographic input.
    var sourceAsset: PropertySourceAsset?

    var isDevelopmentProperty: Bool { lifecycle.isDevelopment }
}

// MARK: - Capture

/// One finished bracket sequence belonging to a room of a property.
struct CaptureItem: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Idempotency key of the shutter action that produced this capture.
    var clientCaptureID: UUID = UUID()
    var propertyID: UUID
    var room: RoomType
    var image: String
    var frameCount: Int
    var jobState: ProcessingJobState
    var createdAt: Date
    var isFavorite: Bool
    /// Immutable original first; every derivative is appended and points back at its parent.
    var assets: [AssetVersion] = []
    /// Captured with no connection and not uploaded yet. Never blocks further photography.
    var isPendingSync: Bool = false
    /// The reference exposure (EV 0) stored in the app container. Present for native captures.
    var localFile: LocalPhotoFile?
    /// Complete local record of the real bracket behind this capture: every exposure, its
    /// metadata and its checksum. Absent for simulated captures.
    var manifest: CaptureManifest?
    /// Where the HDR master stands. `mock` means no real HDR file exists.
    var hdrState: HDRState = .mock
    /// The real, verified HDR master. Only set once its file exists and reads back intact.
    var hdrMaster: HDRMasterRecord?

    var status: PreparationStatus { jobState.userFacing }

    /// What the gallery and photo detail show: the real HDR master once it exists, the EV 0
    /// reference exposure until then. The user never loses access to the photograph.
    var displayFile: LocalPhotoFile? {
        hdrMaster?.masterFile ?? localFile
    }

    /// A capture whose original bytes already live on this device.
    var hasLocalOriginal: Bool { localFile != nil }

    /// Real photographs from the native camera, as opposed to the simulated prototype.
    var captureSource: CaptureSource { manifest?.captureSource ?? .simulated }

    /// REAL only when a verified master file exists; REAL_PROCESSING while the real pipeline
    /// owns the capture; MOCK otherwise.
    var hdrSource: HDRSource {
        switch hdrState {
        case .generated: hdrMaster == nil ? .mock : .real
        case .pending, .processing: .realProcessing
        case .mock, .failed, .sourceRejected: .mock
        }
    }

    /// Every real exposure of this capture, in ladder order.
    var frames: [CaptureFrame] { manifest?.orderedFrames ?? [] }

    var originalAsset: AssetVersion? {
        assets.first { $0.type == .original }
    }

    var shortID: String {
        String(id.uuidString.prefix(8))
    }
}

// MARK: - Assets & lineage

enum AssetType: String, Sendable {
    case original
    case hdrMaster
    case aiDerivative
    case video
    case preview
    case thumbnail
}

/// Originals are immutable: any transformation produces a new asset that points back at its parent.
struct AssetVersion: Identifiable, Hashable, Sendable {
    let id: UUID
    var parentAssetID: UUID?
    var type: AssetType
    var label: String
    var versionNumber: Int
    var createdAt: Date

    var symbol: String {
        switch type {
        case .original: "photo.stack"
        case .hdrMaster: "square.stack.3d.up"
        case .aiDerivative: "sparkles"
        case .video: "play.rectangle"
        case .preview, .thumbnail: "photo"
        }
    }
}

// MARK: - Sync

enum SyncState: String, Sendable {
    case synced
    case pending
    case uploading
    case offline
}
