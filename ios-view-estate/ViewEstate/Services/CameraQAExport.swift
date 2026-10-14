import Foundation

/// Per-frame exposure table (spec: Frame / Requested EV / Actual bias / ISO / Exposure time /
/// Highlight clipping / Shadow clipping), plus the timing and colour columns HDR will need.
enum CameraExposureTable {
    nonisolated static func csv(for manifest: CaptureManifest) -> String {
        var lines = [
            "frame,requested_ev,actual_bias,iso,exposure_time_s,highlight_clip_pct,shadow_clip_pct,"
                + "sensor_timestamp_s,interval_ms,lens_position,wb_temperature_k,wb_tint,bytes",
        ]
        let ordered = manifest.orderedFrames
        let intervals = manifest.frameIntervalsMs
        for (index, frame) in ordered.enumerated() {
            let analysis = CaptureBundleStore.url(for: frame).flatMap(FrameExposureAnalyzer.analyze(url:))
            let interval = index > 0 && index - 1 < intervals.count ? format(intervals[index - 1], "%.1f") : ""
            let fields: [String] = [
                "\(frame.sequenceIndex)",
                format(frame.requestedEV, "%.2f"),
                frame.actualExposureBias.map { format($0, "%.2f") } ?? "",
                frame.iso.map { format($0, "%.0f") } ?? "",
                frame.exposureDurationSeconds.map { format($0, "%.6f") } ?? "",
                analysis.map { format($0.highlightClippingPercent, "%.3f") } ?? "",
                analysis.map { format($0.shadowClippingPercent, "%.3f") } ?? "",
                frame.sensorTimestampSeconds.map { format($0, "%.4f") } ?? "",
                interval,
                frame.lensPosition.map { format($0, "%.4f") } ?? "",
                frame.whiteBalance?.temperature.map { format($0, "%.0f") } ?? "",
                frame.whiteBalance?.tint.map { format($0, "%.2f") } ?? "",
                "\(frame.byteCount)",
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func format(_ value: Double, _ pattern: String) -> String {
        String(format: pattern, value)
    }
}

/// Builds the structured development dataset from tagged physical captures:
///
/// ```
/// qa/camera/<device>/<scene>/<condition>_<id>/frame_*.jpg, manifest.json, exposure_table.csv
/// ```
///
/// Only captures explicitly tagged in the Camera Lab are included, so a customer photograph can
/// never end up in the dataset by accident. Nothing is uploaded anywhere: the archive is handed to
/// the developer through the system share sheet.
enum CameraQADatasetExporter {
    enum ExportError: Error {
        case nothingTagged
        case archiveFailed
    }

    nonisolated static func export(_ manifests: [CaptureManifest]) throws -> URL {
        let tagged = manifests.filter { $0.qaTag != nil && $0.state.isValid }
        guard !tagged.isEmpty else { throw ExportError.nothingTagged }

        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let staging = fileManager.temporaryDirectory.appendingPathComponent("ViewEstate-QA-\(stamp)", isDirectory: true)
        try? fileManager.removeItem(at: staging)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for manifest in tagged {
            guard let tag = manifest.qaTag else { continue }
            let folder = staging
                .appendingPathComponent("qa/camera", isDirectory: true)
                .appendingPathComponent(sanitize(manifest.device), isDirectory: true)
                .appendingPathComponent(tag.scene.folder, isDirectory: true)
                .appendingPathComponent("\(tag.condition.rawValue.lowercased())_\(manifest.clientCaptureID.uuidString.prefix(8))", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            for frame in manifest.orderedFrames {
                guard let source = CaptureBundleStore.url(for: frame) else { continue }
                try? fileManager.copyItem(at: source, to: folder.appendingPathComponent(frame.fileName))
            }
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try Data(CameraExposureTable.csv(for: manifest).utf8).write(to: folder.appendingPathComponent("exposure_table.csv"))
        }

        return try archive(staging, name: "ViewEstate-QA-\(stamp).zip")
    }

    /// Zips a folder with the system's own archiver (file coordination `.forUploading`).
    private nonisolated static func archive(_ folder: URL, name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        try? FileManager.default.removeItem(at: folder)
        guard coordinationError == nil, copyError == nil,
              FileManager.default.fileExists(atPath: destination.path)
        else { throw ExportError.archiveFailed }
        return destination
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
