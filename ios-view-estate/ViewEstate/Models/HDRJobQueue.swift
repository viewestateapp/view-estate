import CryptoKit
import Foundation

/// Lifecycle of one queued HDR job. Developer diagnostics only — a normal user only ever sees
/// "A preparar", "Pronta", "Erro" or "Precisa de nova captura".
nonisolated enum HDRQueueJobState: String, Codable, Hashable, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case ready = "READY"
    case failed = "FAILED"
    /// Still running, but no progress for longer than the stall threshold. A warning, not an end.
    case stalled = "STALLED"
    case cancelled = "CANCELLED"

    /// Occupies (or waits for) the single HDR worker.
    var isActive: Bool { self == .queued || self == .running || self == .stalled }
    var isRunning: Bool { self == .running || self == .stalled }
}

/// One job of the app-level HDR queue. The pipeline is persisted at creation, so what was
/// requested and what actually ran can always be compared.
nonisolated struct HDRQueueJob: Identifiable, Hashable, Sendable {
    let id: UUID
    let captureID: UUID
    let requestedPipeline: HDRPipelineSelection
    /// Set when the worker starts the pipeline.
    var actualPipeline: HDRPipelineSelection?
    var state: HDRQueueJobState
    var stage: HDRStage
    let queuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var lastProgressAt: Date
    var retryCount: Int
    var errorCode: String?
    var errorDetail: String?

    /// Time since the worker started the job (0 while queued).
    func elapsedSeconds(now: Date = .now) -> Double {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    func secondsSinceProgress(now: Date = .now) -> Double {
        (finishedAt ?? now).timeIntervalSince(lastProgressAt)
    }
}

extension HDRStage {
    /// Names used by the developer queue read-out.
    nonisolated var queueLabel: String {
        switch self {
        case .queued: "QUEUED"
        case .validating: "VALIDATING"
        case .decoding: "LOADING"
        case .aligning, .normalizing: "ALIGNING"
        case .analyzingMotion: "MOTION_ANALYSIS"
        case .deghosting: "DEGHOSTING"
        case .merging: "MERGING"
        case .toneMapping: "TONEMAPPING"
        case .denoising: "DENOISING"
        case .sharpening: "SHARPENING"
        case .qualityCheck: "QA"
        case .writing: "WRITING"
        case .verifying: "VERIFYING"
        case .done: "DONE"
        case .failed: "FAILED"
        }
    }
}

/// Lets the queue stop a pipeline that outlived its watchdog. The pipeline checks it between
/// stages and frames; its late result is ignored either way.
nonisolated final class HDRCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Physical input check that runs before any pipeline: every promised exposure must be on the
/// device, readable and byte-identical to its manifest hash, with EV 0 present.
nonisolated struct HDRInputCheckResult: Hashable, Sendable {
    var expected: Int
    var existing: Int
    var readable: Int
    var validHashes: Int
    var hasEV0: Bool
    /// `nil` when the bracket can be processed.
    var errorCode: String?
    var detail: String?

    var summary: String {
        "files \(existing)/\(expected) · readable \(readable)/\(expected) · hashes \(validHashes)/\(expected) · EV0 \(hasEV0 ? "YES" : "NO")"
    }
}

nonisolated enum HDRInputCheck {
    static let filesMissing = "HDR_INPUT_FILES_MISSING"
    static let unreadable = "HDR_INPUT_UNREADABLE"
    static let hashMismatch = "HDR_INPUT_HASH_MISMATCH"
    static let ev0Missing = "HDR_INPUT_EV0_MISSING"

    static func verify(_ manifest: CaptureManifest) -> HDRInputCheckResult {
        let frames = manifest.frames
        let expected = max(manifest.expectedFrameCount, frames.count)
        var existing = 0
        var readable = 0
        var valid = 0
        var firstBad: String?
        for frame in frames {
            guard let url = CaptureBundleStore.url(for: frame),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                firstBad = firstBad ?? frame.fileName
                continue
            }
            existing += 1
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                firstBad = firstBad ?? frame.fileName
                continue
            }
            readable += 1
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if !frame.checksum.isEmpty, hash == frame.checksum { valid += 1 } else { firstBad = firstBad ?? frame.fileName }
        }
        let hasEV0 = frames.contains { abs($0.requestedEV) < 0.01 }

        var result = HDRInputCheckResult(
            expected: expected,
            existing: existing,
            readable: readable,
            validHashes: valid,
            hasEV0: hasEV0
        )
        if !hasEV0 {
            result.errorCode = ev0Missing
        } else if existing < expected {
            result.errorCode = filesMissing
        } else if readable < expected {
            result.errorCode = unreadable
        } else if valid < expected {
            result.errorCode = hashMismatch
        }
        if result.errorCode != nil {
            result.detail = "\(result.summary)\(firstBad.map { " · first bad \($0)" } ?? "")"
        }
        return result
    }
}
