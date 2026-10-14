import Foundation

/// Persists the physical validation session so evidence survives app restarts — the restart
/// itself is one of the tests. Stored locally only; never uploaded.
enum PhysicalValidationStore {
    nonisolated static let key = "ve.camera.validation.session"
    /// Identifies this process, so captures from an earlier launch can be told apart.
    nonisolated static let currentLaunchID = UUID()

    nonisolated static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    nonisolated static func load(defaults: UserDefaults = .standard) -> PhysicalValidationSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PhysicalValidationSession.self, from: data)
    }

    nonisolated static func save(_ session: PhysicalValidationSession?, defaults: UserDefaults = .standard) {
        guard let session else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        defaults.set(data, forKey: key)
    }
}
