import OSLog

/// Diagnostic logging. Only technical facts that help debug the capture pipeline are logged —
/// never user data, credentials or image content.
enum VELog {
    private nonisolated static let cameraLog = Logger(subsystem: "app.viewestate", category: "camera")

    nonisolated static func camera(_ message: String) {
        cameraLog.debug("\(message, privacy: .public)")
    }

    nonisolated static func cameraError(_ code: String, _ detail: String) {
        cameraLog.error("\(code, privacy: .public) — \(detail, privacy: .public)")
    }
}
