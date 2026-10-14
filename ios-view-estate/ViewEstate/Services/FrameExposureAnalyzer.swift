import CoreGraphics
import Foundation
import ImageIO

/// Development-only luminance statistics of one stored exposure.
struct FrameExposureAnalysis: Sendable, Hashable {
    /// 64 bins, normalised so they sum to 1.
    var histogram: [Double]
    /// 0…1
    var meanLuminance: Double
    /// Share of pixels at or above the highlight clip level, percent.
    var highlightClippingPercent: Double
    /// Share of pixels at or below the shadow clip level, percent.
    var shadowClippingPercent: Double
}

/// Reads a downsampled copy of a frame and measures it. The original file is never modified,
/// re-encoded or uploaded anywhere — this exists only to judge whether a ladder is useful.
enum FrameExposureAnalyzer {
    static let binCount = 64
    /// 8-bit levels counted as clipped.
    static let highlightLevel: UInt8 = 250
    static let shadowLevel: UInt8 = 5
    private static let analysisSize = 256

    nonisolated static func analyze(url: URL) -> FrameExposureAnalysis? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return analyze(image: image)
    }

    nonisolated static func analyze(image: CGImage) -> FrameExposureAnalysis? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
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
        guard drawn else { return nil }
        return analyze(luminance: pixels)
    }

    /// Statistics over raw 8-bit luminance values.
    nonisolated static func analyze(luminance pixels: [UInt8]) -> FrameExposureAnalysis? {
        guard !pixels.isEmpty else { return nil }
        var bins = [Int](repeating: 0, count: binCount)
        var sum = 0
        var highlights = 0
        var shadows = 0
        for value in pixels {
            bins[Int(value) * binCount / 256] += 1
            sum += Int(value)
            if value >= highlightLevel { highlights += 1 }
            if value <= shadowLevel { shadows += 1 }
        }
        let total = Double(pixels.count)
        return FrameExposureAnalysis(
            histogram: bins.map { Double($0) / total },
            meanLuminance: Double(sum) / total / 255,
            highlightClippingPercent: Double(highlights) / total * 100,
            shadowClippingPercent: Double(shadows) / total * 100
        )
    }
}

/// Answers, for development only, whether a bracket actually widens usable dynamic range.
/// The heuristics never alter originals and never influence the capture itself.
struct BracketDynamicRangeReport: Sendable, Hashable {
    struct Entry: Sendable, Hashable {
        var requestedEV: Double
        var analysis: FrameExposureAnalysis
    }

    /// Clipping at or under this share counts as "recovered".
    static let recoveredClippingPercent = 0.5
    /// Adjacent exposures closer than this in mean luminance are considered redundant.
    static let redundantLuminanceDelta = 0.02
    /// Extremes darker / brighter than this carry almost no information.
    static let unusableDarkMean = 0.02
    static let unusableBrightMean = 0.98

    var darkestRecoversHighlights: Bool
    var brightestRecoversShadows: Bool
    /// Pairs of adjacent exposures that are practically identical.
    var redundantPairs: [[Double]]
    var adjacentExposuresDistinct: Bool
    var unusableDarkExtreme: Bool
    var unusableBrightExtreme: Bool
    var referenceHighlightClipping: Double?
    var referenceShadowClipping: Double?

    var verdict: String {
        if darkestRecoversHighlights && brightestRecoversShadows && adjacentExposuresDistinct
            && !unusableDarkExtreme && !unusableBrightExtreme {
            return "USEFUL_RANGE"
        }
        if !darkestRecoversHighlights || !brightestRecoversShadows { return "INSUFFICIENT_RANGE" }
        return "REDUNDANT_EXTREMES"
    }

    nonisolated static func evaluate(_ entries: [Entry]) -> BracketDynamicRangeReport? {
        let ordered = entries.sorted { $0.requestedEV < $1.requestedEV }
        guard let darkest = ordered.first, let brightest = ordered.last, ordered.count >= 2 else { return nil }

        var redundant: [[Double]] = []
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            let delta = abs(upper.analysis.meanLuminance - lower.analysis.meanLuminance)
            if delta < redundantLuminanceDelta { redundant.append([lower.requestedEV, upper.requestedEV]) }
        }
        let reference = ordered.first { abs($0.requestedEV) < 0.001 }

        return BracketDynamicRangeReport(
            darkestRecoversHighlights: darkest.analysis.highlightClippingPercent <= recoveredClippingPercent,
            brightestRecoversShadows: brightest.analysis.shadowClippingPercent <= recoveredClippingPercent,
            redundantPairs: redundant,
            adjacentExposuresDistinct: redundant.isEmpty,
            unusableDarkExtreme: darkest.analysis.meanLuminance < unusableDarkMean,
            unusableBrightExtreme: brightest.analysis.meanLuminance > unusableBrightMean,
            referenceHighlightClipping: reference?.analysis.highlightClippingPercent,
            referenceShadowClipping: reference?.analysis.shadowClippingPercent
        )
    }
}
