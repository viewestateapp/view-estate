import Foundation

/// Atomic validation of one capture bundle.
///
/// A shutter action only becomes a capture when everything it promised physically exists on the
/// device: the expected number of frames, the mandatory EV 0 reference, one single camera, one
/// geometry, one orientation, unique sequence indexes and a checksum for every file. An
/// eight-frame FULL_9 is never quietly accepted as valid.
enum CaptureBundleValidator {
    /// - Returns: `nil` when the bundle is valid, otherwise the normalised failure code.
    static func validate(_ manifest: CaptureManifest, deepVerify: Bool = false) -> CameraError? {
        guard CaptureManifest.supportedSchemaVersions.contains(manifest.schemaVersion) else {
            return .manifestInvalid
        }

        let frames = manifest.orderedFrames
        let expected = manifest.requestedLadder
        guard expected.contains(where: { abs($0) < 0.001 }) else { return .ev0Missing }

        // Every frame belongs to this shutter action. Attempts are never mixed.
        guard frames.allSatisfy({ $0.clientCaptureID == manifest.clientCaptureID }) else {
            return .manifestInvalid
        }

        guard manifest.expectedFrameCount == expected.count,
              manifest.actualFrameCount == frames.count
        else { return .manifestInvalid }

        guard frames.count == expected.count else { return .frameMissing }

        guard frames.contains(where: \.isReferenceExposure) else { return .ev0Missing }

        // Deterministic reconstruction: unique, contiguous indexes carrying the exact ladder.
        let indexes = frames.map(\.sequenceIndex)
        guard Set(indexes).count == indexes.count, indexes == Array(0..<frames.count) else {
            return .manifestInvalid
        }
        let matchesLadder = zip(frames, expected).allSatisfy { frame, value in
            abs(frame.requestedEV - value) < 0.01
        }
        guard matchesLadder else { return .manifestInvalid }

        guard let first = frames.first else { return .frameMissing }

        for frame in frames {
            guard !frame.checksum.isEmpty else { return .manifestInvalid }
            guard frame.byteCount > 0, let size = CaptureBundleStore.fileSize(frame), size == frame.byteCount
            else { return .frameMissing }
            guard frame.width == first.width, frame.height == first.height else {
                return .frameDimensionMismatch
            }
            guard frame.orientation == first.orientation, frame.orientation == manifest.orientation else {
                return .frameOrientationMismatch
            }
            guard frame.cameraID == first.cameraID, frame.lensType == first.lensType,
                  frame.cameraID == manifest.cameraID
            else { return .cameraChanged }

            if deepVerify {
                guard let data = CaptureBundleStore.loadData(frame) else { return .frameMissing }
                guard CaptureBundleStore.checksum(data) == frame.checksum else { return .manifestInvalid }
            }
        }

        // Byte-identical exposures are one photograph counted twice, never two real frames.
        let checksums = frames.map(\.checksum)
        guard Set(checksums).count == checksums.count else { return .duplicateFrame }

        return nil
    }
}
