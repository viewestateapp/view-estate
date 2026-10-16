import CoreMotion
import Foundation
import Observation

/// One device-motion sample, gravity already separated from the user's own movement.
struct MotionSample: Sendable, Hashable {
    /// Seconds, monotonic.
    var timestamp: TimeInterval
    /// rad/s
    var rotationX: Double
    var rotationY: Double
    var rotationZ: Double
    /// g, gravity removed
    var accelerationX: Double
    var accelerationY: Double
    var accelerationZ: Double
    /// Unit gravity vector in device coordinates.
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double

    var rotationMagnitude: Double {
        (rotationX * rotationX + rotationY * rotationY + rotationZ * rotationZ).squareRoot()
    }

    var accelerationMagnitude: Double {
        (accelerationX * accelerationX + accelerationY * accelerationY + accelerationZ * accelerationZ).squareRoot()
    }
}

/// What the stability analysis concluded at one moment.
struct StabilityReading: Sendable, Hashable {
    var state: StabilityState
    /// 0 = highly unstable, 1 = perfectly still. Internal only.
    var score: Double
    /// Mean squared rotation rate over the window, (rad/s)².
    var rotationVariance: Double
    /// Mean squared user acceleration over the window, g².
    var accelerationVariance: Double
    var peakRotation: Double
    var peakAcceleration: Double
    /// Movement is beyond the severe threshold right now.
    var isSevere: Bool
    /// Horizon tilt relative to the nearest upright/landscape orientation, degrees (−45…45).
    var rollDegrees: Double
    /// Full in-plane rotation, degrees; drives the on-screen horizon line.
    var horizonDegrees: Double
    /// Camera tilt up/down, degrees. Positive = camera pointing down.
    var pitchDegrees: Double
    var isLevel: Bool
    var sampleCount: Int

    static let idle = StabilityReading(
        state: .stable,
        score: 1,
        rotationVariance: 0,
        accelerationVariance: 0,
        peakRotation: 0,
        peakAcceleration: 0,
        isSevere: false,
        rollDegrees: 0,
        horizonDegrees: 0,
        pitchDegrees: 0,
        isLevel: true,
        sampleCount: 0
    )
}

/// Pure, deterministic stability analysis over a rolling time window.
///
/// Stability is never decided from one reading: the window must stay calm for
/// `minimumStableDurationMs` before the state becomes STABLE.
struct StabilityAnalyzer: Sendable {
    var thresholds: StabilityThresholds
    var levelToleranceDegrees: Double

    private(set) var samples: [MotionSample] = []
    private var calmSince: TimeInterval?

    /// Peaks are judged over a short recent slice so one jolt reacts quickly.
    private let severeWindow: TimeInterval = 0.25

    init(thresholds: StabilityThresholds, levelToleranceDegrees: Double) {
        self.thresholds = thresholds
        self.levelToleranceDegrees = levelToleranceDegrees
    }

    mutating func reset() {
        samples.removeAll()
        calmSince = nil
    }

    mutating func ingest(_ sample: MotionSample) -> StabilityReading {
        samples.append(sample)
        let windowStart = sample.timestamp - thresholds.stabilityWindowMs / 1000
        if let firstKept = samples.firstIndex(where: { $0.timestamp >= windowStart }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }

        let count = Double(samples.count)
        let rotationVariance = samples.reduce(0) { $0 + $1.rotationMagnitude * $1.rotationMagnitude } / count
        let accelerationVariance = samples.reduce(0) { $0 + $1.accelerationMagnitude * $1.accelerationMagnitude } / count

        let recentStart = sample.timestamp - severeWindow
        let recent = samples.filter { $0.timestamp >= recentStart }
        let peakRotation = recent.map(\.rotationMagnitude).max() ?? 0
        let peakAcceleration = recent.map(\.accelerationMagnitude).max() ?? 0
        let isSevere = peakRotation > thresholds.severeRotationRate || peakAcceleration > thresholds.severeAcceleration

        // ratio 1 = exactly at the stability limit.
        let ratio = max(
            rotationVariance / thresholds.maxRotationVariance,
            accelerationVariance / thresholds.maxAccelerationVariance
        )
        let score = Self.score(ratio: ratio)

        let state: StabilityState
        if ratio > 1 || isSevere {
            calmSince = nil
            state = .unstable
        } else {
            let since = calmSince ?? sample.timestamp
            calmSince = since
            let calmMs = (sample.timestamp - since) * 1000
            state = calmMs >= thresholds.minimumStableDurationMs ? .stable : .stabilizing
        }

        let level = Self.level(gravityX: sample.gravityX, gravityY: sample.gravityY, gravityZ: sample.gravityZ)
        return StabilityReading(
            state: state,
            score: score,
            rotationVariance: rotationVariance,
            accelerationVariance: accelerationVariance,
            peakRotation: peakRotation,
            peakAcceleration: peakAcceleration,
            isSevere: isSevere,
            rollDegrees: level.roll,
            horizonDegrees: level.horizon,
            pitchDegrees: level.pitch,
            isLevel: abs(level.roll) <= levelToleranceDegrees,
            sampleCount: samples.count
        )
    }

    /// 1 when perfectly still, 0.5 exactly at the threshold, 0 at twice the threshold or beyond.
    static func score(ratio: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        return min(1, max(0, 1 - ratio / 2))
    }

    /// Roll and pitch from the gravity vector.
    ///
    /// `horizon` is the clockwise in-plane rotation of the phone (0 = upright portrait,
    /// −90 = landscape left); `roll` is that angle relative to the nearest orthogonal orientation,
    /// so both portrait and landscape photographs report how far the horizon is off level.
    static func level(gravityX: Double, gravityY: Double, gravityZ: Double) -> (roll: Double, horizon: Double, pitch: Double) {
        let horizon = atan2(gravityX, -gravityY) * 180 / .pi
        let roll = horizon - 90 * (horizon / 90).rounded()
        let planar = (gravityX * gravityX + gravityY * gravityY).squareRoot()
        let pitch = atan2(-gravityZ, planar) * 180 / .pi
        return (roll, horizon, pitch)
    }
}

/// Accumulates motion across one shutter action.
struct CaptureMotionRecorder: Sendable {
    private(set) var before: StabilityReading?
    private var scores: [Double] = []
    private var maxRotation: Double = 0
    private var maxAcceleration: Double = 0
    private var last: StabilityReading?

    init(before: StabilityReading?) {
        self.before = before
    }

    mutating func record(sample: MotionSample, reading: StabilityReading) {
        scores.append(reading.score)
        maxRotation = max(maxRotation, sample.rotationMagnitude)
        maxAcceleration = max(maxAcceleration, sample.accelerationMagnitude)
        last = reading
    }

    func snapshot(sensorAvailable: Bool, thresholds: StabilityThresholds) -> CaptureMotionSnapshot {
        guard sensorAvailable else { return .unavailable }
        let during = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let minimum = scores.min()
        var snapshot = CaptureMotionSnapshot(
            sensorAvailable: true,
            stabilityBeforeCapture: before?.score,
            stateBeforeCapture: before?.state,
            stabilityDuringCapture: during,
            minimumStabilityDuringCapture: minimum,
            stabilityAtEnd: last?.score,
            maxRotationDuringCapture: scores.isEmpty ? nil : maxRotation,
            maxAccelerationDuringCapture: scores.isEmpty ? nil : maxAcceleration,
            rollAngleAtCapture: before?.rollDegrees,
            pitchAngleAtCapture: before?.pitchDegrees,
            wasLevelAtCapture: before?.isLevel,
            sampleCount: scores.count,
            assessment: .none
        )
        snapshot.assessment = Self.assess(snapshot, thresholds: thresholds)
        return snapshot
    }

    /// Severe motion is flagged, never deleted: the future HDR engine may still align it.
    static func assess(_ snapshot: CaptureMotionSnapshot, thresholds: StabilityThresholds) -> MotionAssessment {
        guard snapshot.sensorAvailable else { return .unavailable }
        if let rotation = snapshot.maxRotationDuringCapture, rotation > thresholds.severeRotationRate { return .severe }
        if let acceleration = snapshot.maxAccelerationDuringCapture, acceleration > thresholds.severeAcceleration { return .severe }
        if let minimum = snapshot.minimumStabilityDuringCapture, minimum < thresholds.motionSevereScore { return .severe }
        if let during = snapshot.stabilityDuringCapture, during < thresholds.motionWarningScore { return .warning }
        if let before = snapshot.stateBeforeCapture, before == .unstable { return .warning }
        return .none
    }
}

/// Real device stability and level, from CoreMotion.
///
/// Owns the motion manager and the rolling-window analysis; views only read the published
/// reading. Published values are throttled so the camera interface is not redrawn at sensor rate.
@Observable
final class CameraStabilityService {
    /// Throttled reading for the interface.
    private(set) var reading: StabilityReading = .idle
    private(set) var isSensorAvailable: Bool = false
    private(set) var isRunning: Bool = false
    /// Physical orientation of the phone (debounced, with hysteresis). Frozen during a bracket.
    private(set) var orientation: CaptureOrientation = .portrait

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var orientationTracker = OrientationTracker()
    @ObservationIgnored private var analyzer: StabilityAnalyzer
    @ObservationIgnored private var latest: StabilityReading = .idle
    @ObservationIgnored private var lastPublishedAt: TimeInterval = 0
    @ObservationIgnored private var recorder: CaptureMotionRecorder?

    private let sampleInterval: TimeInterval = 1.0 / 30.0
    private let publishInterval: TimeInterval = 0.1

    init(calibration: CameraCalibrationProfile = .generic) {
        analyzer = StabilityAnalyzer(
            thresholds: calibration.stabilityThresholds,
            levelToleranceDegrees: calibration.levelToleranceDegrees
        )
    }

    var thresholds: StabilityThresholds { analyzer.thresholds }

    /// Applies a (possibly remote) calibration without restarting the sensor.
    func apply(_ calibration: CameraCalibrationProfile) {
        analyzer.thresholds = calibration.stabilityThresholds
        analyzer.levelToleranceDegrees = calibration.levelToleranceDegrees
        analyzer.reset()
    }

    /// Whether the shutter may fire. Only severe movement can hold it, and only when configured.
    var allowsCapture: Bool {
        !(isSensorAvailable && reading.isSevere && analyzer.thresholds.blockCaptureWhenSevere)
    }

    /// The state shown to a person. Without a sensor nothing is claimed as unstable.
    var displayState: StabilityState {
        isSensorAvailable ? reading.state : .stable
    }

    func start() {
        guard !isRunning else { return }
        isSensorAvailable = manager.isDeviceMotionAvailable
        guard isSensorAvailable else {
            VELog.camera("stability sensor unavailable")
            return
        }
        isRunning = true
        analyzer.reset()
        manager.deviceMotionUpdateInterval = sampleInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated { self.ingest(motion) }
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }

    // MARK: - Orientation

    /// The orientation a capture must use when the shutter is tapped. `nil` without a motion
    /// sensor, so the camera falls back to its own rotation coordinator.
    var captureOrientation: CaptureOrientation? {
        isSensorAvailable ? orientation : nil
    }

    /// Freezes the presented orientation for the duration of a bracket.
    func freezeOrientation() {
        orientationTracker.freeze()
    }

    /// Resumes orientation tracking and adopts wherever the phone ended up.
    func releaseOrientation() {
        orientationTracker.release()
        if orientationTracker.orientation != orientation {
            orientation = orientationTracker.orientation
        }
    }

    // MARK: - Capture window

    /// Freezes the "before" reading (including roll and pitch) at the shutter tap.
    func beginCaptureWindow() {
        recorder = CaptureMotionRecorder(before: isSensorAvailable ? latest : nil)
    }

    /// Ends the window and returns everything recorded during the bracket.
    func endCaptureWindow() -> CaptureMotionSnapshot {
        let snapshot = recorder?.snapshot(sensorAvailable: isSensorAvailable && isRunning, thresholds: analyzer.thresholds)
            ?? .unavailable
        recorder = nil
        return snapshot
    }

    // MARK: - Sampling

    private func ingest(_ motion: CMDeviceMotion) {
        let sample = MotionSample(
            timestamp: motion.timestamp,
            rotationX: motion.rotationRate.x,
            rotationY: motion.rotationRate.y,
            rotationZ: motion.rotationRate.z,
            accelerationX: motion.userAcceleration.x,
            accelerationY: motion.userAcceleration.y,
            accelerationZ: motion.userAcceleration.z,
            gravityX: motion.gravity.x,
            gravityY: motion.gravity.y,
            gravityZ: motion.gravity.z
        )
        let next = analyzer.ingest(sample)
        latest = next
        let physical = orientationTracker.ingest(
            gravityX: sample.gravityX,
            gravityY: sample.gravityY,
            timestamp: sample.timestamp
        )
        if physical != orientation { orientation = physical }
        recorder?.record(sample: sample, reading: next)

        let stateChanged = next.state != reading.state || next.isSevere != reading.isSevere || next.isLevel != reading.isLevel
        if stateChanged || sample.timestamp - lastPublishedAt >= publishInterval {
            reading = next
            lastPublishedAt = sample.timestamp
        }
    }
}
