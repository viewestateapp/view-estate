import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why an HDR job did not produce a master.
nonisolated struct HDRProcessingFailure: Error, Sendable {
    enum Kind: Sendable {
        /// Something broke (unreadable file, decode or write error, timeout) → "Erro".
        case technical
        /// The bracket itself cannot make an acceptable HDR → "Precisa de nova captura".
        case sourceRejected
    }

    var code: String
    var kind: Kind
    var detail: String
}

/// The first real HDR pipeline. Runs entirely on the device, costs no credits and never
/// modifies a source exposure — the master is a new, derived file next to them.
///
/// REAL exposure files → validate (bracket audit) → decode → align to EV 0 (median threshold
/// bitmaps) → weighted radiance merge → global tone mapping → write HDR master + preview →
/// read back and verify.
///
/// Known limits of this minimum version: translation-only alignment, no ghost removal, and the
/// camera's processed JPEGs are linearised with a gamma approximation rather than a measured
/// response curve.
nonisolated enum HDRProcessingService {
    static let pipelineVersion = "VE-HDR 1.0 (MTB align · weighted radiance merge · Reinhard)"
    static let masterFileName = "hdr_master_v1.jpg"
    static let previewFileName = "hdr_preview_v1.jpg"
    static let recordFileName = "hdr_master.json"
    /// Longest edge of the master. Bounds memory to roughly 250 MB on a 12 MP sensor.
    static let workingMaxPixel = 3024
    static let previewMaxPixel = 1280
    static let alignmentMaxPixel = 800
    /// A job can never keep a photo preparing forever.
    static let timeoutSeconds: Double = 120

    private static let gamma: Float = 2.2
    /// Keeps EV 0 mid-grey (0.18) at the same brightness after tone mapping.
    private static let keyScale: Float = 1.22
    private static let weightFloor: Float = 0.0001
    private static let flags = vImage_Flags(kvImageNoFlags)

    // MARK: - Entry point

    static func process(
        manifest: CaptureManifest,
        captureID: UUID,
        progress: @Sendable (HDRStage) -> Void
    ) -> Result<HDRMasterRecord, HDRProcessingFailure> {
        let started = Date()
        do {
            progress(.validating)
            let sources = try validatedSources(manifest)

            progress(.decoding)
            guard let referenceURL = CaptureBundleStore.url(for: sources.reference) else {
                throw HDRProcessingFailure(code: "HDR_SOURCE_UNREADABLE", kind: .technical, detail: "EV 0 path")
            }
            let reference = try decodeRGBX(url: referenceURL, maxPixel: workingMaxPixel)
            let referenceGray = try decodeGray(url: referenceURL, maxPixel: alignmentMaxPixel)
            let width = reference.width
            let height = reference.height
            let count = width * height
            let shiftScale = Double(width) / Double(referenceGray.width)
            let maxShift = max(4, width / 30)

            let accumulator = Accumulator(width: width, height: height)
            let scratch = MergeScratch(width: width, height: height)
            let darkest = sources.frames.map(\.ev).min() ?? 0
            let brightest = sources.frames.map(\.ev).max() ?? 0
            var alignment: [String] = []

            for source in sources.frames {
                let isReference = source.frame.id == sources.reference.id
                let aligned: PixelPlane<UInt8>
                if isReference {
                    progress(.merging)
                    aligned = reference.plane
                } else {
                    guard let url = CaptureBundleStore.url(for: source.frame) else {
                        throw HDRProcessingFailure(code: "HDR_SOURCE_UNREADABLE", kind: .technical, detail: source.frame.fileName)
                    }
                    let image = try decodeRGBX(url: url, maxPixel: workingMaxPixel)
                    guard image.width == width, image.height == height else {
                        throw HDRProcessingFailure(code: "HDR_GEOMETRY_MISMATCH", kind: .sourceRejected, detail: source.frame.fileName)
                    }
                    progress(.aligning)
                    let gray = try decodeGray(url: url, maxPixel: alignmentMaxPixel)
                    let shift = MedianThresholdAligner.align(reference: referenceGray, image: gray)
                    var dx = Int((Double(shift.dx) * shiftScale).rounded())
                    var dy = Int((Double(shift.dy) * shiftScale).rounded())
                    var note = ""
                    if !shift.isReliable {
                        dx = 0
                        dy = 0
                        note = " (low texture, unaligned)"
                    } else if abs(dx) > maxShift || abs(dy) > maxShift {
                        dx = 0
                        dy = 0
                        note = " (shift too large, unaligned)"
                    }
                    alignment.append("EV \(source.frame.evLabel): \(dx >= 0 ? "+" : "")\(dx), \(dy >= 0 ? "+" : "")\(dy)\(note)")
                    aligned = translate(image.plane, width: width, height: height, dx: dx, dy: dy)
                    progress(.merging)
                }

                let weighting: HatSide
                if abs(source.ev - darkest) < 0.01 {
                    weighting = .keepHighlights
                } else if abs(source.ev - brightest) < 0.01 {
                    weighting = .keepShadows
                } else {
                    weighting = .symmetric
                }
                try accumulate(
                    aligned,
                    exposure: Float(pow(2.0, source.ev)),
                    weighting: weighting,
                    into: accumulator,
                    scratch: scratch,
                    count: count
                )
            }

            progress(.toneMapping)
            let output = try toneMap(accumulator, scratch: scratch, width: width, height: height)

            let ev0Stats = clipStats(reference.plane, count: count)
            let hdrStats = clipStats(output, count: count)

            progress(.writing)
            guard let image = makeImage(output, width: width, height: height) else {
                throw HDRProcessingFailure(code: "HDR_ENCODE_FAILED", kind: .technical, detail: "CGImage")
            }
            let orientation = sources.reference.exifOrientation
            guard let masterData = jpegData(image, orientation: orientation, quality: 0.92),
                  let previewData = previewData(from: masterData, orientation: orientation)
            else {
                throw HDRProcessingFailure(code: "HDR_ENCODE_FAILED", kind: .technical, detail: "JPEG")
            }
            guard let masterURL = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: masterFileName),
                  let previewURL = CaptureBundleStore.url(clientCaptureID: manifest.clientCaptureID, fileName: previewFileName)
            else {
                throw HDRProcessingFailure(code: "HDR_WRITE_FAILED", kind: .technical, detail: "bundle path")
            }
            do {
                try masterData.write(to: masterURL, options: .atomic)
                try previewData.write(to: previewURL, options: .atomic)
            } catch {
                throw HDRProcessingFailure(code: "HDR_WRITE_FAILED", kind: .technical, detail: "write")
            }

            // READY only once the master really exists and reads back intact.
            progress(.verifying)
            let checksum = CaptureBundleStore.checksum(masterData)
            guard let stored = try? Data(contentsOf: masterURL),
                  stored.count == masterData.count,
                  CaptureBundleStore.checksum(stored) == checksum,
                  let dimensions = pixelDimensions(of: stored),
                  dimensions.width == width, dimensions.height == height
            else {
                throw HDRProcessingFailure(code: "HDR_VERIFY_FAILED", kind: .technical, detail: "read back")
            }

            let record = HDRMasterRecord(
                assetID: UUID(),
                captureID: captureID,
                clientCaptureID: manifest.clientCaptureID,
                fileName: masterFileName,
                previewFileName: previewFileName,
                pixelWidth: width,
                pixelHeight: height,
                exifOrientation: orientation,
                orientation: sources.reference.orientation,
                byteCount: stored.count,
                previewByteCount: previewData.count,
                checksum: checksum,
                pipelineVersion: pipelineVersion,
                createdAt: .now,
                sourceFrameCount: sources.frames.count,
                distinctExposureLevels: sources.distinctLevels,
                referenceFileName: sources.reference.fileName,
                alignment: alignment,
                processingSeconds: Date().timeIntervalSince(started),
                ev0HighlightClipPercent: ev0Stats.highlight,
                ev0ShadowClipPercent: ev0Stats.shadow,
                hdrHighlightClipPercent: hdrStats.highlight,
                hdrShadowClipPercent: hdrStats.shadow
            )
            try HDRMasterStore.write(record)
            progress(.done)
            return .success(record)
        } catch let failure as HDRProcessingFailure {
            return .failure(failure)
        } catch {
            return .failure(HDRProcessingFailure(code: "HDR_INTERNAL_ERROR", kind: .technical, detail: "unexpected"))
        }
    }

    // MARK: - Validation

    private struct SourceFrame {
        var frame: CaptureFrame
        /// Measured exposure relative to EV 0, in EV.
        var ev: Double
    }

    private struct Sources {
        var reference: CaptureFrame
        var frames: [SourceFrame]
        var distinctLevels: Int
    }

    /// Only real frames go in: persisted, checksum-verified from disk, unique, with EV 0.
    private static func validatedSources(_ manifest: CaptureManifest) throws -> Sources {
        guard manifest.state.isValid else {
            throw HDRProcessingFailure(code: "HDR_SOURCE_INVALID", kind: .sourceRejected, detail: manifest.state.devLabel)
        }
        let frames = manifest.orderedFrames
        let plan = BracketPlan(profile: manifest.captureProfile, segments: [manifest.requestedLadder], reason: "")
        let audit = BracketAuditor.audit(frames: frames, plan: plan, evidence: .unknown, verifyFromDisk: true)

        guard audit.persistedFiles == frames.count, audit.verifiedChecksums == frames.count else {
            throw HDRProcessingFailure(code: "HDR_SOURCE_UNREADABLE", kind: .technical, detail: "files or checksums")
        }
        guard audit.supportsHDR, let reference = frames.first(where: \.isReferenceExposure) else {
            throw HDRProcessingFailure(
                code: "HDR_INSUFFICIENT_EXPOSURES",
                kind: .sourceRejected,
                detail: "real=\(audit.realFrames) distinct=\(audit.distinctExposureLevels)"
            )
        }

        var seen: Set<String> = []
        let relative = BracketAuditor.relativeExposures(frames)
        let unique = frames.filter { seen.insert($0.checksum).inserted }
        // EV 0 first, so every other exposure is aligned to it.
        let ordered = unique.sorted { lhs, rhs in
            if lhs.id == reference.id { return true }
            if rhs.id == reference.id { return false }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return Sources(
            reference: reference,
            frames: ordered.map { SourceFrame(frame: $0, ev: relative[$0.id] ?? $0.requestedEV) },
            distinctLevels: audit.distinctExposureLevels
        )
    }

    // MARK: - Merge

    private enum HatSide {
        case symmetric
        /// Darkest exposure: its bright pixels are the only trustworthy highlight data.
        case keepHighlights
        /// Brightest exposure: its dark pixels are the cleanest shadow data.
        case keepShadows
    }

    private final class Accumulator {
        let red: PixelPlane<Float>
        let green: PixelPlane<Float>
        let blue: PixelPlane<Float>
        let weight: PixelPlane<Float>

        init(width: Int, height: Int) {
            red = PixelPlane(width: width, height: height)
            green = PixelPlane(width: width, height: height)
            blue = PixelPlane(width: width, height: height)
            weight = PixelPlane(width: width, height: height)
            for plane in [red, green, blue, weight] {
                vDSP_vclr(plane.pointer, 1, vDSP_Length(plane.count))
            }
        }
    }

    private final class MergeScratch {
        let red: PixelPlane<UInt8>
        let green: PixelPlane<UInt8>
        let blue: PixelPlane<UInt8>
        let a: PixelPlane<Float>
        let b: PixelPlane<Float>
        let linearTable: [Float]

        init(width: Int, height: Int) {
            red = PixelPlane(width: width, height: height)
            green = PixelPlane(width: width, height: height)
            blue = PixelPlane(width: width, height: height)
            a = PixelPlane(width: width, height: height)
            b = PixelPlane(width: width, height: height)
            linearTable = (0..<256).map { powf(Float($0) / 255, HDRProcessingService.gamma) }
        }
    }

    /// Adds one aligned exposure: radiance = Σ w·linear / Σ w·exposure, with a hat weight on
    /// the brightest channel and exposure-proportional confidence (longer = cleaner).
    private static func accumulate(
        _ image: PixelPlane<UInt8>,
        exposure: Float,
        weighting: HatSide,
        into accumulator: Accumulator,
        scratch: MergeScratch,
        count: Int
    ) throws {
        let n = vDSP_Length(count)
        var source = image.buffer(bytesPerPixel: 4)
        var red = scratch.red.buffer(bytesPerPixel: 1)
        var green = scratch.green.buffer(bytesPerPixel: 1)
        var blue = scratch.blue.buffer(bytesPerPixel: 1)
        var a = scratch.a.buffer(bytesPerPixel: 4)
        var b = scratch.b.buffer(bytesPerPixel: 4)

        try check(vImageExtractChannel_ARGB8888(&source, &red, 0, flags))
        try check(vImageExtractChannel_ARGB8888(&source, &green, 1, flags))
        try check(vImageExtractChannel_ARGB8888(&source, &blue, 2, flags))

        // a = max(R, G, B) in 0…1
        try check(vImageConvert_Planar8toPlanarF(&red, &a, 1, 0, flags))
        try check(vImageConvert_Planar8toPlanarF(&green, &b, 1, 0, flags))
        vDSP_vmax(scratch.a.pointer, 1, scratch.b.pointer, 1, scratch.a.pointer, 1, n)
        try check(vImageConvert_Planar8toPlanarF(&blue, &b, 1, 0, flags))
        vDSP_vmax(scratch.a.pointer, 1, scratch.b.pointer, 1, scratch.a.pointer, 1, n)

        // t = 2a − 1, one-sided for the extreme exposures
        var two: Float = 2
        var minusOne: Float = -1
        var zero: Float = 0
        var one: Float = 1
        vDSP_vsmsa(scratch.a.pointer, 1, &two, &minusOne, scratch.a.pointer, 1, n)
        switch weighting {
        case .symmetric: break
        case .keepHighlights: vDSP_vclip(scratch.a.pointer, 1, &minusOne, &zero, scratch.a.pointer, 1, n)
        case .keepShadows: vDSP_vclip(scratch.a.pointer, 1, &zero, &one, scratch.a.pointer, 1, n)
        }

        // w = max(1 − t¹², floor)
        vDSP_vsq(scratch.a.pointer, 1, scratch.a.pointer, 1, n)
        vDSP_vsq(scratch.a.pointer, 1, scratch.b.pointer, 1, n)
        vDSP_vsq(scratch.b.pointer, 1, scratch.a.pointer, 1, n)
        vDSP_vmul(scratch.a.pointer, 1, scratch.b.pointer, 1, scratch.a.pointer, 1, n)
        vDSP_vsmsa(scratch.a.pointer, 1, &minusOne, &one, scratch.a.pointer, 1, n)
        var minimumWeight = weightFloor
        vDSP_vthr(scratch.a.pointer, 1, &minimumWeight, scratch.a.pointer, 1, n)

        // Σ w·linear per channel; Σ w·exposure once
        try scratch.linearTable.withUnsafeBufferPointer { table in
            guard let lut = table.baseAddress else { return }
            for (channel, target) in [(red, accumulator.red), (green, accumulator.green), (blue, accumulator.blue)] {
                var planar = channel
                try check(vImageLookupTable_Planar8toPlanarF(&planar, &b, lut, flags))
                vDSP_vma(scratch.a.pointer, 1, scratch.b.pointer, 1, target.pointer, 1, target.pointer, 1, n)
            }
        }
        var factor = exposure
        vDSP_vsma(scratch.a.pointer, 1, &factor, accumulator.weight.pointer, 1, accumulator.weight.pointer, 1, n)
    }

    /// Radiance → display: extended Reinhard with the white point at the 99.5th percentile,
    /// scaled so EV 0 mid-tones keep their brightness, then gamma encoded to 8-bit sRGB.
    private static func toneMap(
        _ accumulator: Accumulator,
        scratch: MergeScratch,
        width: Int,
        height: Int
    ) throws -> PixelPlane<UInt8> {
        let count = width * height
        let n = vDSP_Length(count)
        let channels = [accumulator.red, accumulator.green, accumulator.blue]
        for channel in channels {
            vDSP_vdiv(accumulator.weight.pointer, 1, channel.pointer, 1, channel.pointer, 1, n)
            var key = keyScale
            vDSP_vsmul(channel.pointer, 1, &key, channel.pointer, 1, n)
        }

        // White point from a sparse sample of the brightest channel.
        var samples: [Float] = []
        samples.reserveCapacity(count / 61 + 1)
        var index = 0
        while index < count {
            let value = max(accumulator.red.pointer[index], accumulator.green.pointer[index], accumulator.blue.pointer[index])
            if value.isFinite { samples.append(value) }
            index += 61
        }
        samples.sort()
        let percentile = samples.isEmpty ? 1 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.995))]
        let white = max(Float(1), percentile)

        var zero: Float = 0
        var one: Float = 1
        var inverseWhiteSquared = 1 / (white * white)
        var exponent = 1 / gamma
        var length = Int32(count)
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        let alpha = PixelPlane<UInt8>(width: width, height: height)
        memset(alpha.pointer, 255, alpha.count)
        let encoded = [scratch.red, scratch.green, scratch.blue]

        for (channel, target) in zip(channels, encoded) {
            // y = x·(1 + x/w²) / (1 + x)
            vDSP_vsmsa(channel.pointer, 1, &inverseWhiteSquared, &one, scratch.a.pointer, 1, n)
            vDSP_vmul(channel.pointer, 1, scratch.a.pointer, 1, scratch.a.pointer, 1, n)
            vDSP_vsadd(channel.pointer, 1, &one, scratch.b.pointer, 1, n)
            vDSP_vdiv(scratch.b.pointer, 1, scratch.a.pointer, 1, scratch.a.pointer, 1, n)
            vDSP_vclip(scratch.a.pointer, 1, &zero, &one, scratch.a.pointer, 1, n)
            vvpowsf(scratch.a.pointer, &exponent, scratch.a.pointer, &length)
            var floatBuffer = scratch.a.buffer(bytesPerPixel: 4)
            var byteBuffer = target.buffer(bytesPerPixel: 1)
            try check(vImageConvert_PlanarFtoPlanar8(&floatBuffer, &byteBuffer, 1, 0, flags))
        }

        var red = scratch.red.buffer(bytesPerPixel: 1)
        var green = scratch.green.buffer(bytesPerPixel: 1)
        var blue = scratch.blue.buffer(bytesPerPixel: 1)
        var alphaBuffer = alpha.buffer(bytesPerPixel: 1)
        var destination = output.buffer(bytesPerPixel: 4)
        // Byte order in memory: R, G, B, X — matching `noneSkipLast`.
        try check(vImageConvert_Planar8toARGB8888(&red, &green, &blue, &alphaBuffer, &destination, flags))
        return output
    }

    // MARK: - Pixels

    private static func check(_ error: vImage_Error) throws {
        guard error == kvImageNoError else {
            throw HDRProcessingFailure(code: "HDR_PROCESSING_FAILED", kind: .technical, detail: "vImage \(error)")
        }
    }

    private struct DecodedImage {
        var plane: PixelPlane<UInt8>
        var width: Int
        var height: Int
    }

    /// Sensor-orientation decode (no EXIF transform), so every exposure shares one geometry.
    private static func decodeRGBX(url: URL, maxPixel: Int) throws -> DecodedImage {
        guard let image = thumbnail(url: url, maxPixel: maxPixel) else {
            throw HDRProcessingFailure(code: "HDR_DECODE_FAILED", kind: .technical, detail: url.lastPathComponent)
        }
        let width = image.width
        let height = image.height
        let plane = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: plane.pointer,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            throw HDRProcessingFailure(code: "HDR_DECODE_FAILED", kind: .technical, detail: "context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(plane: plane, width: width, height: height)
    }

    private static func decodeGray(url: URL, maxPixel: Int) throws -> GrayImage {
        guard let image = thumbnail(url: url, maxPixel: maxPixel) else {
            throw HDRProcessingFailure(code: "HDR_DECODE_FAILED", kind: .technical, detail: url.lastPathComponent)
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw HDRProcessingFailure(code: "HDR_DECODE_FAILED", kind: .technical, detail: "gray context")
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    private static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// aligned(x, y) = source(x + dx, y + dy), edges extended.
    private static func translate(_ source: PixelPlane<UInt8>, width: Int, height: Int, dx: Int, dy: Int) -> PixelPlane<UInt8> {
        guard dx != 0 || dy != 0 else { return source }
        let output = PixelPlane<UInt8>(width: width, height: height, channels: 4)
        let rowBytes = width * 4
        let first = min(width, max(0, -dx))
        let last = max(-1, min(width - 1, width - 1 - dx))
        for y in 0..<height {
            let sourceY = min(max(y + dy, 0), height - 1)
            let sourceRow = source.pointer + sourceY * rowBytes
            let row = output.pointer + y * rowBytes
            if last >= first {
                memcpy(row + first * 4, sourceRow + (first + dx) * 4, (last - first + 1) * 4)
            }
            if first > 0 {
                for x in 0..<first { memcpy(row + x * 4, sourceRow, 4) }
            }
            if last + 1 < width {
                for x in (last + 1)..<width { memcpy(row + x * 4, sourceRow + (width - 1) * 4, 4) }
            }
        }
        return output
    }

    /// Share of pixels with a clipped highlight (brightest channel ≥ 250) and crushed shadow
    /// (brightest channel ≤ 6), sampled.
    private static func clipStats(_ plane: PixelPlane<UInt8>, count: Int) -> (highlight: Double, shadow: Double) {
        var highlight = 0
        var shadow = 0
        var sampled = 0
        var index = 0
        while index < count {
            let base = plane.pointer + index * 4
            let value = max(base[0], base[1], base[2])
            if value >= 250 { highlight += 1 }
            if value <= 6 { shadow += 1 }
            sampled += 1
            index += 7
        }
        guard sampled > 0 else { return (0, 0) }
        return (Double(highlight) / Double(sampled) * 100, Double(shadow) / Double(sampled) * 100)
    }

    private static func makeImage(_ plane: PixelPlane<UInt8>, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: plane.pointer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
    }

    private static func jpegData(_ image: CGImage, orientation: Int, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: pipelineVersion],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func previewData(from master: Data, orientation: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(master as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return jpegData(image, orientation: orientation, quality: 0.85)
    }

    private static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

// MARK: - Storage

/// The HDR master record lives in the capture bundle, next to the exposures it came from, so it
/// survives an app restart.
nonisolated enum HDRMasterStore {
    static func write(_ record: HDRMasterRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let url = CaptureBundleStore.url(clientCaptureID: record.clientCaptureID, fileName: HDRProcessingService.recordFileName),
              let data = try? encoder.encode(record)
        else {
            throw HDRProcessingFailure(code: "HDR_WRITE_FAILED", kind: .technical, detail: "record")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw HDRProcessingFailure(code: "HDR_WRITE_FAILED", kind: .technical, detail: "record write")
        }
    }

    /// The record of a master whose file still exists with the recorded size. Anything else is
    /// treated as "no master".
    static func read(clientCaptureID: UUID) -> HDRMasterRecord? {
        guard let url = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: HDRProcessingService.recordFileName),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(HDRMasterRecord.self, from: data),
              let master = CaptureBundleStore.url(clientCaptureID: clientCaptureID, fileName: record.fileName),
              let attributes = try? FileManager.default.attributesOfItem(atPath: master.path),
              (attributes[.size] as? NSNumber)?.intValue == record.byteCount
        else { return nil }
        return record
    }

    static func path(_ record: HDRMasterRecord) -> String {
        CaptureBundleStore.url(clientCaptureID: record.clientCaptureID, fileName: record.fileName)?.path ?? record.fileName
    }
}

// MARK: - Buffers

/// Tightly packed pixel memory (rowBytes = width × channels), freed automatically.
nonisolated final class PixelPlane<Element> {
    let width: Int
    let height: Int
    let channels: Int
    let count: Int
    let pointer: UnsafeMutablePointer<Element>

    init(width: Int, height: Int, channels: Int = 1) {
        self.width = width
        self.height = height
        self.channels = channels
        count = width * height * channels
        pointer = UnsafeMutablePointer<Element>.allocate(capacity: max(1, count))
    }

    deinit {
        pointer.deallocate()
    }

    func buffer(bytesPerPixel: Int) -> vImage_Buffer {
        vImage_Buffer(
            data: UnsafeMutableRawPointer(pointer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width * bytesPerPixel
        )
    }
}

nonisolated struct GrayImage: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

/// Exposure-invariant, translation-only alignment (Ward's median threshold bitmaps).
nonisolated enum MedianThresholdAligner {
    struct Shift: Sendable {
        var dx: Int
        var dy: Int
        /// Enough textured pixels survived the exclusion band to trust the result.
        var isReliable: Bool
    }

    private static let exclusionBand = 4
    private static let minimumLevelSide = 24
    private static let maxLevels = 6

    static func align(reference: GrayImage, image: GrayImage) -> Shift {
        guard reference.width == image.width, reference.height == image.height else {
            return Shift(dx: 0, dy: 0, isReliable: false)
        }
        var referencePyramid = [reference]
        var imagePyramid = [image]
        while referencePyramid.count < maxLevels,
              let last = referencePyramid.last,
              min(last.width, last.height) / 2 >= minimumLevelSide,
              let lastImage = imagePyramid.last {
            referencePyramid.append(halve(last))
            imagePyramid.append(halve(lastImage))
        }

        var dx = 0
        var dy = 0
        var reliable = true
        for level in stride(from: referencePyramid.count - 1, through: 0, by: -1) {
            dx *= 2
            dy *= 2
            let ref = bitmaps(referencePyramid[level])
            let img = bitmaps(imagePyramid[level])
            if level == 0 {
                let total = referencePyramid[0].width * referencePyramid[0].height
                let textured = img.textured
                reliable = textured >= total / 20 && ref.textured >= total / 20
            }
            var best = Int.max
            var bestDX = dx
            var bestDY = dy
            for offsetY in -1...1 {
                for offsetX in -1...1 {
                    let error = difference(ref, img, width: referencePyramid[level].width, height: referencePyramid[level].height, dx: dx + offsetX, dy: dy + offsetY)
                    if error < best {
                        best = error
                        bestDX = dx + offsetX
                        bestDY = dy + offsetY
                    }
                }
            }
            dx = bestDX
            dy = bestDY
        }
        return Shift(dx: dx, dy: dy, isReliable: reliable)
    }

    private static func halve(_ image: GrayImage) -> GrayImage {
        let width = image.width / 2
        let height = image.height / 2
        var output = [UInt8](repeating: 0, count: width * height)
        image.pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    let top = 2 * y * image.width
                    let bottom = top + image.width
                    for x in 0..<width {
                        let sum = Int(source[top + 2 * x]) + Int(source[top + 2 * x + 1])
                            + Int(source[bottom + 2 * x]) + Int(source[bottom + 2 * x + 1])
                        destination[y * width + x] = UInt8(sum / 4)
                    }
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: output)
    }

    private struct Bitmaps {
        var threshold: [UInt8]
        var exclusion: [UInt8]
        var textured: Int
    }

    private static func bitmaps(_ image: GrayImage) -> Bitmaps {
        var histogram = [Int](repeating: 0, count: 256)
        for value in image.pixels { histogram[Int(value)] += 1 }
        let half = image.pixels.count / 2
        var cumulative = 0
        var median = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half {
                median = value
                break
            }
        }
        var threshold = [UInt8](repeating: 0, count: image.pixels.count)
        var exclusion = [UInt8](repeating: 0, count: image.pixels.count)
        var textured = 0
        image.pixels.withUnsafeBufferPointer { pixels in
            threshold.withUnsafeMutableBufferPointer { thresholdBits in
                exclusion.withUnsafeMutableBufferPointer { exclusionBits in
                    for index in 0..<pixels.count {
                        let value = Int(pixels[index])
                        thresholdBits[index] = value > median ? 1 : 0
                        if abs(value - median) > exclusionBand {
                            exclusionBits[index] = 1
                            textured += 1
                        }
                    }
                }
            }
        }
        return Bitmaps(threshold: threshold, exclusion: exclusion, textured: textured)
    }

    /// Mismatching, non-excluded pixels between reference(x, y) and image(x + dx, y + dy).
    private static func difference(_ ref: Bitmaps, _ img: Bitmaps, width: Int, height: Int, dx: Int, dy: Int) -> Int {
        let xStart = max(0, -dx)
        let xEnd = min(width, width - dx)
        let yStart = max(0, -dy)
        let yEnd = min(height, height - dy)
        guard xEnd > xStart, yEnd > yStart else { return Int.max }
        var errors = 0
        ref.threshold.withUnsafeBufferPointer { refThreshold in
            ref.exclusion.withUnsafeBufferPointer { refExclusion in
                img.threshold.withUnsafeBufferPointer { imgThreshold in
                    img.exclusion.withUnsafeBufferPointer { imgExclusion in
                        for y in yStart..<yEnd {
                            let refRow = y * width
                            let imgRow = (y + dy) * width + dx
                            for x in xStart..<xEnd {
                                let r = refRow + x
                                let i = imgRow + x
                                errors += Int((refThreshold[r] ^ imgThreshold[i]) & refExclusion[r] & imgExclusion[i])
                            }
                        }
                    }
                }
            }
        }
        return errors
    }
}
