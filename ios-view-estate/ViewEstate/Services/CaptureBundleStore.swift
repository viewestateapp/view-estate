import CryptoKit
import Foundation
import ImageIO

/// Local-first storage for one shutter action and every real frame it produced.
///
/// Layout inside the application container:
///
/// ```
/// Captures/
///   <clientCaptureID>/
///     frame_00_ev_-4.jpg
///     …
///     frame_04_ev_0.jpg
///     …
///     manifest.json
/// ```
///
/// Frames are written as they arrive, so a nine-frame bracket never holds nine full-resolution
/// images in memory. Nothing here touches the user's Photos library: these are internal working
/// assets, and the future HDR master is the only thing that may ever be exported.
enum CaptureBundleStore {
    private static let rootName = "Captures"
    private static let manifestName = "manifest.json"

    // MARK: - Locations

    nonisolated static func root() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent(rootName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    nonisolated static func directory(_ clientCaptureID: UUID, create: Bool = true) throws -> URL {
        let directory = try root().appendingPathComponent(clientCaptureID.uuidString, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    nonisolated static func url(clientCaptureID: UUID, fileName: String) -> URL? {
        guard let directory = try? directory(clientCaptureID, create: false) else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated static func url(for frame: CaptureFrame) -> URL? {
        url(clientCaptureID: frame.clientCaptureID, fileName: frame.fileName)
    }

    nonisolated static func path(for frame: CaptureFrame) -> String {
        url(for: frame)?.path ?? frame.fileName
    }

    // MARK: - Frames

    /// Writes one real photograph and describes it completely: dimensions, EXIF orientation,
    /// size and checksum. The bytes are stored exactly as the camera produced them.
    ///
    /// - Throws: `CameraError.frameSaveFailed` for any storage or metadata problem.
    nonisolated static func writeFrame(
        photoData: Data,
        clientCaptureID: UUID,
        sequenceIndex: Int,
        requestedEV: Double,
        orientation: CaptureOrientation,
        cameraID: String,
        lensType: String,
        capturedAt: Date = .now
    ) throws -> CaptureFrame {
        guard let properties = imageProperties(of: photoData) else {
            throw CameraError.frameSaveFailed
        }

        let fileName = fileName(sequenceIndex: sequenceIndex, requestedEV: requestedEV)
        do {
            let destination = try directory(clientCaptureID).appendingPathComponent(fileName, isDirectory: false)
            try photoData.write(to: destination, options: .atomic)
        } catch {
            throw CameraError.frameSaveFailed
        }

        return CaptureFrame(
            clientCaptureID: clientCaptureID,
            sequenceIndex: sequenceIndex,
            requestedEV: requestedEV,
            width: properties.width,
            height: properties.height,
            exifOrientation: properties.orientation,
            orientation: orientation,
            cameraID: cameraID,
            lensType: lensType,
            fileName: fileName,
            byteCount: photoData.count,
            checksum: checksum(photoData),
            capturedAt: capturedAt
        )
    }

    nonisolated static func fileName(sequenceIndex: Int, requestedEV: Double) -> String {
        String(format: "frame_%02d_ev_%@.jpg", sequenceIndex, CaptureProfile.evLabel(requestedEV))
    }

    nonisolated static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func loadData(_ frame: CaptureFrame) -> Data? {
        guard let url = url(for: frame) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Confirms a frame's bytes are on disk and match what the manifest claims.
    nonisolated static func fileSize(_ frame: CaptureFrame) -> Int? {
        guard let url = url(for: frame),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    // MARK: - Manifest

    nonisolated static func writeManifest(_ manifest: CaptureManifest) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            let destination = try directory(manifest.clientCaptureID)
                .appendingPathComponent(manifestName, isDirectory: false)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw CameraError.manifestInvalid
        }
    }

    nonisolated static func readManifest(clientCaptureID: UUID) -> CaptureManifest? {
        guard let url = try? directory(clientCaptureID, create: false)
            .appendingPathComponent(manifestName, isDirectory: false),
            let data = try? Data(contentsOf: url)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureManifest.self, from: data)
    }

    /// Every capture bundle currently on the device, newest first.
    nonisolated static func allManifests() -> [CaptureManifest] {
        guard let root = try? root(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { readManifest(clientCaptureID: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Cleanup

    nonisolated static func delete(clientCaptureID: UUID) {
        guard let directory = try? directory(clientCaptureID, create: false) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes bundles that never became a valid capture and are older than the retention window.
    /// Failed attempts are debugging evidence during development, so nothing is deleted eagerly —
    /// this is the deliberate, bounded cleanup a production build runs.
    @discardableResult
    nonisolated static func cleanupIncomplete(
        olderThan lifetime: TimeInterval = CaptureRetention.incompleteLifetime,
        now: Date = .now
    ) -> Int {
        var removed = 0
        for manifest in allManifests() where !manifest.state.isValid {
            let reference = manifest.completedAt ?? manifest.startedAt
            guard now.timeIntervalSince(reference) > lifetime else { continue }
            delete(clientCaptureID: manifest.clientCaptureID)
            removed += 1
        }
        return removed
    }

    // MARK: - Helpers

    private nonisolated static func imageProperties(
        of data: Data
    ) -> (width: Int, height: Int, orientation: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (width, height, orientation)
    }
}

/// How long an incomplete capture bundle is kept before production cleanup may remove it.
enum CaptureRetention {
    static let incompleteLifetime: TimeInterval = 60 * 60 * 24 * 7
}
