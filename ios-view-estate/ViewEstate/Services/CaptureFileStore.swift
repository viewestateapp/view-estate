import Foundation
import ImageIO

/// Application-owned storage for original photographs.
///
/// Files live inside the app container (Application Support), so a capture never needs
/// connectivity and is never written into the user's Photos library. The bytes the camera
/// produced are stored untouched — the original is immutable — and a small JSON record next to
/// each photograph keeps the association with its capture, property and room.
enum CaptureFileStore {
    private static let folderName = "Captures"

    /// Directory that holds every original photograph and its record.
    nonisolated static func directory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    nonisolated static func url(for fileName: String) -> URL? {
        guard let directory = try? directory() else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Absolute path shown in the developer panel.
    nonisolated static func path(for file: LocalPhotoFile) -> String {
        url(for: file.fileName)?.path ?? file.fileName
    }

    /// Writes one original photograph. Named after the shutter action that produced it, so a
    /// replayed completion event for the same attempt can never create a second file.
    ///
    /// - Throws: `CameraError.localSaveFailed` for any storage or metadata problem.
    nonisolated static func saveOriginal(
        photoData: Data,
        clientCaptureID: UUID,
        orientation: CaptureOrientation,
        createdAt: Date = .now
    ) throws -> LocalPhotoFile {
        guard let properties = imageProperties(of: photoData) else {
            throw CameraError.localSaveFailed
        }

        do {
            let fileName = "capture_\(clientCaptureID.uuidString).jpg"
            let destination = try directory().appendingPathComponent(fileName, isDirectory: false)
            try photoData.write(to: destination, options: .atomic)

            return LocalPhotoFile(
                fileName: fileName,
                pixelWidth: properties.width,
                pixelHeight: properties.height,
                exifOrientation: properties.orientation,
                orientation: orientation,
                byteCount: photoData.count,
                createdAt: createdAt
            )
        } catch {
            throw CameraError.localSaveFailed
        }
    }

    /// Stores the local record of a capture: identifiers, file, dimensions and orientation.
    nonisolated static func writeRecord(_ record: CaptureFileRecord) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(record)
            let destination = try directory()
                .appendingPathComponent("capture_\(record.clientCaptureID.uuidString).json", isDirectory: false)
            try data.write(to: destination, options: .atomic)
        } catch {
            // The photograph itself is already safely on disk; the record is a convenience.
            VELog.camera("record write failed for capture \(record.captureID.uuidString.prefix(8))")
        }
    }

    nonisolated static func readRecord(clientCaptureID: UUID) -> CaptureFileRecord? {
        guard let url = try? directory()
            .appendingPathComponent("capture_\(clientCaptureID.uuidString).json", isDirectory: false),
            let data = try? Data(contentsOf: url)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureFileRecord.self, from: data)
    }

    nonisolated static func loadData(_ file: LocalPhotoFile) -> Data? {
        guard let url = url(for: file.fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Reads dimensions and the EXIF orientation tag without decoding the whole image.
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
