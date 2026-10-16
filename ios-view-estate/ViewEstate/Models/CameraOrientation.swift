import CoreMotion
import Foundation
import Observation
import SwiftUI

/// How the physical-orientation-aware surfaces (camera, photo viewer) present themselves.
///
/// The app shell is portrait-only. The camera keeps its hardware-fixed layout — the 4:3 preview
/// rectangle IS a landscape 4:3 frame once the phone is held sideways — and rotates its overlay
/// and glyphs so they read upright, exactly like a real camera. The capture itself uses the same
/// orientation, frozen at the tap, so preview, overlay, saved frames and manifest always agree.
extension CaptureOrientation {
    var isLandscape: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }

    /// Rotation that makes interface content read upright on a portrait-locked screen.
    ///
    /// `landscapeRight` (capture angle 0) is the phone turned counter-clockwise — its top points
    /// left — so content turns clockwise by 90°; `landscapeLeft` is the mirror case.
    var interfaceRotation: Angle {
        switch self {
        case .portrait: .zero
        case .landscapeRight: .degrees(90)
        case .landscapeLeft: .degrees(-90)
        case .portraitUpsideDown: .degrees(180)
        }
    }

    /// Plain-language description for developer diagnostics.
    var physicalDescription: String {
        switch self {
        case .portrait: "upright"
        case .landscapeRight: "top of phone to the left"
        case .landscapeLeft: "top of phone to the right"
        case .portraitUpsideDown: "upside down"
        }
    }
}

/// Physical orientation from gravity, with hysteresis and debounce.
///
/// - A new orientation is only considered once the phone is within `captureBand` degrees of it,
///   i.e. 15° past the 45° boundary, so hovering near the diagonal never flips the interface.
/// - It must hold for `debounce` seconds before it is adopted.
/// - Face up / face down (little in-plane gravity) and upside-down keep the last orientation.
/// - While frozen (a bracket is running) the published orientation never changes; the pending
///   candidate is adopted as soon as it is released.
struct OrientationTracker: Sendable {
    var captureBand: Double = 30
    var debounce: TimeInterval = 0.22
    /// Minimum in-plane gravity (g) for the reading to say anything about orientation.
    var minimumPlanarGravity: Double = 0.45

    private(set) var orientation: CaptureOrientation = .portrait
    private(set) var isFrozen = false
    private var candidate: CaptureOrientation?
    private var candidateSince: TimeInterval = 0

    init() {}

    mutating func freeze() { isFrozen = true }

    mutating func release() {
        isFrozen = false
        if let candidate { orientation = candidate }
        candidate = nil
    }

    /// Feeds one gravity sample; returns the orientation to present.
    @discardableResult
    mutating func ingest(gravityX: Double, gravityY: Double, timestamp: TimeInterval) -> CaptureOrientation {
        guard let detected = Self.detect(
            gravityX: gravityX,
            gravityY: gravityY,
            band: captureBand,
            minimumPlanarGravity: minimumPlanarGravity
        ) else {
            return orientation
        }

        if isFrozen {
            // Remember where the phone ended up; nothing visible changes mid-bracket.
            candidate = detected == orientation ? nil : detected
            return orientation
        }

        guard detected != orientation else {
            candidate = nil
            return orientation
        }
        if candidate != detected {
            candidate = detected
            candidateSince = timestamp
        } else if timestamp - candidateSince >= debounce {
            orientation = detected
            candidate = nil
        }
        return orientation
    }

    /// The supported orientation the phone is clearly in, or `nil` when it is ambiguous, flat or
    /// upside down. `horizon` is the clockwise in-plane rotation (0 = upright, −90 = top left).
    static func detect(
        gravityX: Double,
        gravityY: Double,
        band: Double = 30,
        minimumPlanarGravity: Double = 0.45
    ) -> CaptureOrientation? {
        let planar = (gravityX * gravityX + gravityY * gravityY).squareRoot()
        guard planar >= minimumPlanarGravity else { return nil }
        let horizon = atan2(gravityX, -gravityY) * 180 / .pi
        if abs(horizon) <= band { return .portrait }
        if abs(horizon + 90) <= band { return .landscapeRight }
        if abs(horizon - 90) <= band { return .landscapeLeft }
        return nil
    }
}

/// Lightweight physical orientation for surfaces that are not the camera (the photo viewer).
///
/// Uses CoreMotion rather than `UIDevice` orientation: it keeps working with the system rotation
/// lock and with the portrait-only app shell.
@Observable
final class PhysicalOrientationService {
    private(set) var orientation: CaptureOrientation = .portrait

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var tracker = OrientationTracker()

    func start() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              manager.isDeviceMotionAvailable,
              !manager.isDeviceMotionActive
        else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 15.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                let next = self.tracker.ingest(
                    gravityX: motion.gravity.x,
                    gravityY: motion.gravity.y,
                    timestamp: motion.timestamp
                )
                if next != self.orientation { self.orientation = next }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// Lays content out in PHYSICAL coordinates inside a portrait-locked area: in landscape the
/// content gets the swapped size and is rotated to read upright, so a header sits at the
/// physical top of the frame and a footer at its physical bottom.
struct OrientedContainer<Content: View>: View {
    let orientation: CaptureOrientation
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let swapped = orientation.isLandscape
            let width = swapped ? geometry.size.height : geometry.size.width
            let height = swapped ? geometry.size.width : geometry.size.height
            content
                .frame(width: width, height: height)
                .rotationEffect(orientation.interfaceRotation)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}
