import AVFoundation
import CoreMedia
import ImageIO
import Observation
import UIKit

/// Everything one shutter action produced at the hardware level.
struct BracketCaptureResult: Sendable {
    var plan: BracketPlan
    var frames: [CaptureFrame]
    var orientation: CaptureOrientation
    var cameraID: String
    var lensType: String
    var deviceModel: String
    var systemVersion: String
    var preparation: SequencePreparation
    var lens: CaptureLensRecord?
    var calibration: CameraCalibrationProfile
    var startedAt: Date
    var completedAt: Date
    /// Real measurements, in seconds.
    var firstFrameSeconds: Double?
    var bracketSeconds: Double
    var persistSeconds: Double
    /// Shutter tap → first native capture request, ms.
    var tapToCaptureStartMs: Double?
    /// First capture request → last frame delivered, ms.
    var bracketDurationMs: Double?
    /// Shutter tap → first frame delivered, ms.
    var tapToFirstFrameMs: Double? = nil
    /// What AVFoundation really did: requests issued and callbacks received.
    var callbackEvidence: BracketAuditor.CallbackEvidence = .unknown

    var focusLock: LockOutcome { preparation.focusLock }
    var whiteBalanceLock: LockOutcome { preparation.whiteBalanceLock }

    var isComplete: Bool { frames.count == plan.expectedFrameCount }
}

/// A bracket that did not finish. The frames that did reach the device are carried along so the
/// attempt can be recorded as incomplete instead of silently disappearing.
struct BracketCaptureFailure: Error, Sendable {
    var code: CameraError
    var partial: BracketCaptureResult
}

/// Native camera for the capture flow: real rear camera preview and, on one shutter action, a
/// real multi-exposure bracket of the exact same composition.
///
/// This service owns the AVFoundation session and nothing else. It never registers captures,
/// never touches the portfolio and never decides idempotency — that stays in `AppState`, keyed on
/// the capture attempt. It also never merges anything: HDR is deliberately absent, the frames it
/// produces are untouched camera output.
@Observable
final class CameraService {
    // MARK: - Observable state

    private(set) var access: CameraAccess = .unknown
    private(set) var isRunning: Bool = false
    private(set) var setup: CameraSetup?
    /// What the real active camera reports it can do.
    private(set) var capabilities: CameraExposureCapabilities?
    /// The ladder the next shutter action will photograph.
    private(set) var plan: BracketPlan = .single
    /// Last normalised failure, ready to be shown as friendly copy.
    private(set) var failure: CameraError?
    /// Calibration resolved for this device and camera.
    private(set) var calibration: CameraCalibrationProfile = .generic
    /// Internal focus state; developer diagnostics only.
    private(set) var focusStatus: FocusStatus = .unavailable
    /// The physical lens in use.
    private(set) var activeLens: PreferredLens?
    /// Measured average size of one exposure, for the storage preflight.
    var averageFrameBytes: Int64?

    /// The live session the preview layer binds to.
    let session = AVCaptureSession()

    // MARK: - Private

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "app.viewestate.camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var focusObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    /// AVFoundation only holds its delegate for the duration of a capture; keep it alive here.
    private var captureDelegate: SequenceCaptureDelegate?
    private var captureRotationAngle: CGFloat = 90
    private var sessionObservers: [NSObjectProtocol] = []
    /// Set by a session interruption, a runtime error or the app leaving the foreground.
    private var interruptionFlag = false
    private var isCaptureInFlight = false
    /// The camera screen wants the session live; drives recovery after interruptions.
    private var wantsRunning = false
    /// Development hook: session lifecycle events for the physical validation log.
    @ObservationIgnored var onSessionEvent: ((CameraSessionEventKind) -> Void)?

    // MARK: - Permission

    /// Resolves the real iOS camera permission, asking for it when the user has not decided yet.
    @discardableResult
    func requestAccess() async -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .authorized
        case .notDetermined:
            access = .notDetermined
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted ? .authorized : .denied
        case .denied:
            access = .denied
        case .restricted:
            access = .restricted
        @unknown default:
            access = .denied
        }

        if access.needsSystemSettings {
            failure = .permissionDenied
            VELog.cameraError(CameraError.permissionDenied.code, "access=\(access.devLabel)")
        }
        return access
    }

    /// Opens iOS Settings so the user can grant camera access.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Lifecycle

    /// Requests access, configures the session once and starts the preview.
    ///
    /// - Parameter lensOverride: development-only lens choice (the ultra-wide test); otherwise
    ///   the calibration profile's preferred lens is used.
    func start(lensOverride: PreferredLens? = nil) async {
        wantsRunning = true
        let access = await requestAccess()
        guard access.isAuthorized else { return }

        // The lens is part of the calibration, so it is resolved before the camera is chosen.
        calibration = CameraCalibrationCatalog.resolve(
            deviceModel: Self.deviceModelName(),
            systemVersion: UIDevice.current.systemVersion
        )
        let lens = lensOverride ?? calibration.preferredLens

        if !isConfigured {
            do {
                try await configure(lens: lens)
                isConfigured = true
                failure = nil
            } catch {
                let normalized = (error as? CameraError) ?? .initializationFailed
                failure = normalized
                VELog.cameraError(normalized.code, "configuration")
                return
            }
        } else if lens != activeLens, !isCaptureInFlight {
            await switchLens(to: lens)
        }

        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
        guard wantsRunning else {
            // The screen closed while the session was starting.
            stop()
            return
        }
        isRunning = session.isRunning
        applyRotationAngles()
        // Bracket size depends on the running session's preset and active format, so capabilities
        // are only meaningful once the camera is actually live.
        readCapabilities()
    }

    /// Stops the session when the camera leaves the screen or the app goes to the background.
    func stop() {
        wantsRunning = false
        guard isConfigured else { return }
        isRunning = false
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Records that something took the camera away mid-sequence. A bracket that meets this flag
    /// is never completed as if it had succeeded.
    func markInterrupted() {
        guard isCaptureInFlight else { return }
        interruptionFlag = true
    }

    /// True only when the session can genuinely accept a capture request right now.
    ///
    /// AVFoundation treats a capture request with no active video connection as a programming
    /// error and raises an exception that cannot be caught, so every request is preflighted:
    /// a camera taken away by the system becomes a normal, recorded failure instead.
    private func isReadyForCapture() -> Bool {
        guard isConfigured, session.isRunning, !interruptionFlag else { return false }
        guard let connection = photoOutput.connection(with: .video) else { return false }
        return connection.isActive && connection.isEnabled
    }

    /// JPEG is requested explicitly only when the active camera actually offers it; otherwise the
    /// output's own default processed format is used.
    private func processedFormat() -> [String: Any]? {
        photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? [AVVideoCodecKey: AVVideoCodecType.jpeg]
            : nil
    }

    /// Binds the preview layer so rotation stays level with gravity in every orientation.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        guard let device else { return }
        makeRotationCoordinator(for: device)
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    private func configure(lens: PreferredLens) async throws {
        guard let device = Self.preferredCamera(lens: lens) else {
            throw CameraError.initializationFailed
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.initializationFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [session, photoOutput] in
                session.beginConfiguration()
                // `.photo` gives the native 4:3 sensor composition the approved viewfinder uses,
                // so the preview is never stretched and every bracket frame shares one geometry.
                if session.canSetSessionPreset(.photo) {
                    session.sessionPreset = .photo
                }

                guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
                    session.commitConfiguration()
                    continuation.resume(throwing: CameraError.initializationFailed)
                    return
                }
                session.addInput(input)
                session.addOutput(photoOutput)

                photoOutput.maxPhotoQualityPrioritization = .quality
                // Photo dimensions are deliberately left at the output's default, which is the
                // SMALLEST entry of the active format's supported dimensions — exactly the base
                // geometry a nine-frame bracket needs. Assigning dimensions read before the
                // preset change is committed can reference a format that is no longer active,
                // which AVFoundation rejects with a fatal exception.
                session.commitConfiguration()
                continuation.resume()
            }
        }

        adopt(device: device, input: input)
        observeSession()
        VELog.camera("session configured device=\(device.localizedName) preset=photo lens=\(activeLens?.devLabel ?? "—")")
    }

    /// Swaps the physical camera between attempts — never during one.
    private func switchLens(to lens: PreferredLens) async {
        guard let current = videoInput,
              let next = Self.preferredCamera(lens: lens),
              next.uniqueID != current.device.uniqueID,
              let input = try? AVCaptureDeviceInput(device: next)
        else { return }

        let swapped: Bool = await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                session.beginConfiguration()
                session.removeInput(current)
                let added = session.canAddInput(input)
                session.addInput(added ? input : current)
                session.commitConfiguration()
                continuation.resume(returning: added)
            }
        }
        guard swapped else { return }
        adopt(device: next, input: input)
        VELog.camera("lens switched to \(activeLens?.devLabel ?? "—") between attempts")
    }

    private func adopt(device: AVCaptureDevice, input: AVCaptureDeviceInput) {
        self.device = device
        videoInput = input
        activeLens = Self.lens(of: device)
        makeRotationCoordinator(for: device)
        setup = Self.describe(device)
        observeFocus(device)
    }

    /// The preferred rear camera. Lenses are never switched automatically during an attempt: a
    /// single physical device is chosen up front, so no frame of a bracket can come from another
    /// lens. Ultra-wide is only used when a calibration (or the developer lens test) asks for it.
    /// External devices are included so an injected camera is found when no built-in one exists.
    private static func preferredCamera(lens: PreferredLens) -> AVCaptureDevice? {
        if lens == .ultraWide,
           let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return ultraWide
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        return devices.first { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.position == .back }
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
    }

    private static func lens(of device: AVCaptureDevice) -> PreferredLens? {
        switch device.deviceType {
        case .builtInWideAngleCamera: .wide
        case .builtInUltraWideCamera: .ultraWide
        default: nil
        }
    }

    private static func describe(_ device: AVCaptureDevice) -> CameraSetup {
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.first
        let resolution = dimensions.map { "\($0.width) × \($0.height)" } ?? "—"
        return CameraSetup(
            deviceName: Self.deviceModelName() + " · " + device.localizedName,
            deviceID: device.uniqueID,
            lens: Self.lensLabel(device),
            captureResolution: resolution,
            systemVersion: "iOS " + UIDevice.current.systemVersion
        )
    }

    /// Hardware identifier (`iPhone16,1`), so a report names the real device, not "iPhone".
    nonisolated static func deviceModelName() -> String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        let identifier = withUnsafeBytes(of: machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }

    private static func lensLabel(_ device: AVCaptureDevice) -> String {
        let type: String
        switch device.deviceType {
        case .builtInWideAngleCamera: type = "Wide"
        case .builtInUltraWideCamera: type = "Ultra Wide"
        case .builtInTelephotoCamera: type = "Telephoto"
        case .external: type = "External"
        default: type = device.deviceType.rawValue
        }
        let position: String
        switch device.position {
        case .back: position = "Rear"
        case .front: position = "Front"
        default: position = "Unspecified"
        }
        return "\(position) \(type)"
    }

    // MARK: - Capability detection

    /// Reads the real exposure envelope of the active camera and plans the ladder from it.
    /// Nothing is assumed: a device that cannot reach ±4 EV gets the widest ladder it supports.
    private func readCapabilities() {
        guard let device else {
            capabilities = nil
            plan = .single
            return
        }

        // Re-resolved with the physical camera: a profile may be pinned to one camera.
        calibration = CameraCalibrationCatalog.resolve(
            deviceModel: Self.deviceModelName(),
            systemVersion: UIDevice.current.systemVersion,
            cameraUniqueID: device.uniqueID
        )

        let format = device.activeFormat
        let dimensions = format.supportedMaxPhotoDimensions.first
        let resolution = dimensions.map { "\($0.width)×\($0.height)" } ?? "—"

        let detected = CameraExposureCapabilities(
            deviceModel: Self.deviceModelName(),
            systemVersion: "iOS " + UIDevice.current.systemVersion,
            activeLens: Self.lensLabel(device),
            cameraID: device.uniqueID,
            activeFormat: resolution,
            minExposureBias: Double(device.minExposureTargetBias),
            maxExposureBias: Double(device.maxExposureTargetBias),
            maxBracketCount: photoOutput.maxBracketedCapturePhotoCount,
            supportsBracketCapture: photoOutput.maxBracketedCapturePhotoCount >= 2,
            supportsExposureLock: device.isExposureModeSupported(.locked),
            supportsCustomExposure: device.isExposureModeSupported(.custom),
            supportsFocusLock: device.isFocusModeSupported(.locked),
            supportsWhiteBalanceLock: device.isWhiteBalanceModeSupported(.locked),
            supportsLensStabilization: photoOutput.isLensStabilizationDuringBracketedCaptureSupported
        )
        capabilities = detected
        plan = CaptureProfileService.plan(for: detected, calibration: calibration)
        VELog.camera(
            "capabilities bias=\(detected.minExposureBias)…\(detected.maxExposureBias) "
                + "maxBracket=\(detected.maxBracketCount) profile=\(plan.profile.devLabel) "
                + "segments=\(plan.segments.count) calibration=\(calibration.versionLabel)"
        )
    }

    // MARK: - Session events & recovery

    private func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default

        sessionObservers.append(
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markInterrupted()
                    self.isRunning = false
                    self.onSessionEvent?(.interrupted)
                    VELog.camera("session interrupted duringCapture=\(self.isCaptureInFlight)")
                }
            }
        )

        sessionObservers.append(
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    VELog.camera("session interruption ended")
                    self?.onSessionEvent?(.interruptionEnded)
                    self?.recoverSession()
                }
            }
        )

        sessionObservers.append(
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
                let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code
                let mediaServicesReset = code == .mediaServicesWereReset
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markInterrupted()
                    self.isRunning = false
                    self.onSessionEvent?(.runtimeError)
                    VELog.camera("session runtime error mediaServicesReset=\(mediaServicesReset)")
                    // Media services reset (or a transient error) is recoverable by restarting.
                    self.recoverSession()
                }
            }
        )

        for name in [AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification] {
            sessionObservers.append(
                center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isRunning = self.session.isRunning
                    }
                }
            )
        }
    }

    /// Restarts the session after an interruption, a lock/unlock or a media-services reset —
    /// only if the camera screen still wants it. Never creates a capture record.
    private func recoverSession() {
        guard wantsRunning, isConfigured, access.isAuthorized else { return }
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = running
                self.onSessionEvent?(running ? .recovered : .recoveryFailed)
                if running {
                    self.applyRotationAngles()
                    self.readCapabilities()
                }
            }
        }
    }

    private func observeFocus(_ device: AVCaptureDevice) {
        focusStatus = device.isFocusModeSupported(.autoFocus) ? .ready : .unavailable
        guard device.isFocusModeSupported(.autoFocus) else {
            focusObservation = nil
            return
        }
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] camera, _ in
            let adjusting = camera.isAdjustingFocus
            Task { @MainActor [weak self] in
                guard let self, !self.isCaptureInFlight else { return }
                self.focusStatus = adjusting ? .searching : .ready
            }
        }
    }

    // MARK: - Rotation

    private func makeRotationCoordinator(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in
                self?.applyPreviewRotation(angle)
            }
        }

        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor [weak self] in
                self?.captureRotationAngle = angle
            }
        }
    }

    private func applyRotationAngles() {
        guard let coordinator = rotationCoordinator else { return }
        captureRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Capture

    /// Photographs the planned exposure ladder for ONE shutter action.
    ///
    /// Composition is held still for the whole sequence: one physical camera, zoom 1.0, focus and
    /// white balance locked where the hardware allows it, one orientation frozen at the tap, and
    /// exposure varied only by the requested bias relative to a settled, centre-metered EV 0
    /// reference. Frames are written to the capture bundle as they arrive, so the device never
    /// holds the whole bracket in memory.
    ///
    /// - Parameters:
    ///   - tapAt: when the shutter was tapped, for tap-to-capture latency.
    ///   - availableBytesOverride: development-only low-storage simulation.
    /// - Throws: `BracketCaptureFailure` carrying a normalised code and whatever was persisted.
    func captureBracket(
        clientCaptureID: UUID,
        tapAt: Date = .now,
        availableBytesOverride: Int64? = nil
    ) async throws -> BracketCaptureResult {
        guard access.isAuthorized else {
            throw BracketCaptureFailure(code: .permissionDenied, partial: emptyResult(clientCaptureID))
        }
        guard isConfigured, session.isRunning, let device else {
            throw BracketCaptureFailure(code: .initializationFailed, partial: emptyResult(clientCaptureID))
        }

        let plan = self.plan
        let calibration = self.calibration

        // Never begin a bracket that is likely to run out of space halfway through.
        let available = availableBytesOverride ?? CaptureStoragePolicy.availableBytes()
        guard CaptureStoragePolicy.hasRoom(
            frameCount: plan.expectedFrameCount,
            averageFrameBytes: averageFrameBytes,
            availableBytes: available
        ) else {
            failure = .insufficientStorage
            VELog.cameraError(CameraError.insufficientStorage.code, "frames=\(plan.expectedFrameCount)")
            throw BracketCaptureFailure(code: .insufficientStorage, partial: emptyResult(clientCaptureID))
        }

        let startedAt = Date()
        // Orientation is frozen at the top of the attempt: rotating the phone mid-bracket never
        // gives individual frames different orientations.
        let angle = captureRotationAngle
        let orientation = CaptureOrientation(videoRotationAngle: angle)
        let cameraID = device.uniqueID
        let lensType = Self.lensLabel(device)

        interruptionFlag = false
        isCaptureInFlight = true
        defer { isCaptureInFlight = false }

        guard isReadyForCapture() else {
            throw BracketCaptureFailure(code: .initializationFailed, partial: emptyResult(clientCaptureID))
        }

        let preparation = await prepareForSequence(strategy: calibration)

        if preparation.focusTimeout, calibration.focusStrategy.onTimeout == .requireRetry {
            restoreContinuousModes()
            var partial = emptyResult(clientCaptureID)
            partial.preparation = preparation
            failure = .focusTimeout
            VELog.cameraError(CameraError.focusTimeout.code, "policy=requireRetry")
            throw BracketCaptureFailure(code: .focusTimeout, partial: partial)
        }

        let context = SequenceContext(
            clientCaptureID: clientCaptureID,
            orientation: orientation,
            cameraID: cameraID,
            lensType: lensType,
            isBracket: plan.profile.isBracket,
            probe: DeviceProbe(device)
        )

        var frames: [CaptureFrame] = []
        var persistSeconds: Double = 0
        var firstPhotoAt: Date?
        var firstRequestAt: Date?
        var lastFrameAt: Date?
        var failureCode: CameraError?
        var evidence = BracketAuditor.CallbackEvidence.unknown

        segments: for segment in plan.segments {
            if interruptionFlag {
                failureCode = .captureInterrupted
                break segments
            }

            if firstRequestAt == nil { firstRequestAt = Date() }
            let outcome = await captureSegment(
                exposures: segment,
                baseIndex: frames.count,
                rotationAngle: angle,
                context: context
            )

            evidence.nativeRequests += outcome.requestIssued ? 1 : 0
            evidence.framesPerRequest.append(outcome.frames.count)
            evidence.callbacks += outcome.callbacks
            evidence.callbackErrors += outcome.callbackErrors
            evidence.indexCollisions += outcome.indexCollisions
            frames.append(contentsOf: outcome.frames)
            persistSeconds += outcome.persistSeconds
            if firstPhotoAt == nil { firstPhotoAt = outcome.firstPhotoAt }
            lastFrameAt = outcome.lastPhotoAt ?? lastFrameAt

            if let code = outcome.failure {
                failureCode = code
                break segments
            }
            if outcome.frames.count != segment.count {
                failureCode = .frameMissing
                break segments
            }
        }

        let lens = lensRecord(for: device, frames: frames)
        restoreContinuousModes()

        let completedAt = Date()
        let result = BracketCaptureResult(
            plan: plan,
            frames: frames.sorted { $0.sequenceIndex < $1.sequenceIndex },
            orientation: orientation,
            cameraID: cameraID,
            lensType: lensType,
            deviceModel: Self.deviceModelName(),
            systemVersion: "iOS " + UIDevice.current.systemVersion,
            preparation: preparation,
            lens: lens,
            calibration: calibration,
            startedAt: startedAt,
            completedAt: completedAt,
            firstFrameSeconds: firstPhotoAt.map { $0.timeIntervalSince(startedAt) },
            bracketSeconds: completedAt.timeIntervalSince(startedAt),
            persistSeconds: persistSeconds,
            tapToCaptureStartMs: firstRequestAt.map { $0.timeIntervalSince(tapAt) * 1000 },
            bracketDurationMs: firstRequestAt.flatMap { start in
                (lastFrameAt ?? completedAt).timeIntervalSince(start) * 1000
            },
            tapToFirstFrameMs: firstPhotoAt.map { $0.timeIntervalSince(tapAt) * 1000 },
            callbackEvidence: evidence
        )

        if interruptionFlag { failureCode = .captureInterrupted }
        if failureCode == nil, !result.isComplete { failureCode = .frameMissing }

        if let failureCode {
            failure = failureCode
            // The camera's envelope may have changed underneath the attempt, so the next shutter
            // action plans from a freshly read capability set.
            readCapabilities()
            VELog.cameraError(
                failureCode.code,
                "profile=\(plan.profile.devLabel) frames=\(frames.count)/\(plan.expectedFrameCount)"
            )
            throw BracketCaptureFailure(code: failureCode, partial: result)
        }

        failure = nil
        if !frames.isEmpty {
            averageFrameBytes = Int64(frames.reduce(0) { $0 + $1.byteCount } / frames.count)
        }
        VELog.camera(
            "bracket \(plan.profile.devLabel) frames=\(result.frames.count) "
                + "duration=\(Int(result.bracketDurationMs ?? 0))ms tap=\(Int(result.tapToCaptureStartMs ?? 0))ms "
                + "focus=\(preparation.focusStatus.devLabel) wbLock=\(preparation.whiteBalanceLock.devLabel)"
        )
        return result
    }

    private func emptyResult(_ clientCaptureID: UUID) -> BracketCaptureResult {
        let now = Date()
        return BracketCaptureResult(
            plan: plan,
            frames: [],
            orientation: CaptureOrientation(videoRotationAngle: captureRotationAngle),
            cameraID: device?.uniqueID ?? "—",
            lensType: device.map(Self.lensLabel) ?? "—",
            deviceModel: Self.deviceModelName(),
            systemVersion: "iOS " + UIDevice.current.systemVersion,
            preparation: .unavailable,
            lens: nil,
            calibration: calibration,
            startedAt: now,
            completedAt: now,
            firstFrameSeconds: nil,
            bracketSeconds: 0,
            persistSeconds: 0,
            tapToCaptureStartMs: nil,
            bracketDurationMs: nil
        )
    }

    private func lensRecord(for device: AVCaptureDevice, frames: [CaptureFrame]) -> CaptureLensRecord {
        let reference = frames.first(where: \.isReferenceExposure) ?? frames.first
        return CaptureLensRecord(
            cameraUniqueID: device.uniqueID,
            deviceType: device.deviceType.rawValue,
            lens: Self.lens(of: device),
            focalLengthMM: reference?.focalLengthMM,
            focalLengthEquivalentMM: reference?.metadata["focalLength35mm"].flatMap(Double.init),
            fieldOfViewDegrees: Double(device.activeFormat.videoFieldOfView),
            zoomFactor: Double(device.videoZoomFactor),
            lensAperture: Double(device.lensAperture),
            lensModel: reference?.metadata["lensModel"],
            calibrationDataSupported: photoOutput.isCameraCalibrationDataDeliverySupported
        )
    }

    /// One native capture request: a bracket of up to `maxBracketCount` exposures, or a single
    /// photograph when the camera cannot bracket at all.
    private func captureSegment(
        exposures: [Double],
        baseIndex: Int,
        rotationAngle: CGFloat,
        context: SequenceContext
    ) async -> SegmentOutcome {
        guard !exposures.isEmpty else { return SegmentOutcome(failure: .frameMissing) }
        guard isReadyForCapture() else {
            return SegmentOutcome(failure: interruptionFlag ? .captureInterrupted : .initializationFailed)
        }

        let wantsBracket = context.isBracket && plan.profile.isBracket
        if wantsBracket {
            // The live limit is re-read for every request: it changes with the session preset and
            // the active format, and asking for more exposures than the camera supports is a
            // fatal AVFoundation exception rather than an error callback.
            guard photoOutput.maxBracketedCapturePhotoCount >= exposures.count else {
                return SegmentOutcome(failure: .bracketNotSupported)
            }
            // Likewise, a bias outside the camera's reported envelope is rejected fatally.
            if let capabilities {
                guard CaptureProfileService.fits(exposures, capabilities: capabilities) else {
                    return SegmentOutcome(failure: .exposureRangeUnsupported)
                }
            }
        }

        let settings: AVCapturePhotoSettings
        if wantsBracket {
            let bracketed = exposures.map {
                AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                    exposureTargetBias: Float($0)
                )
            }
            // Bracketed capture only supports a small set of inherited settings — flash,
            // stabilisation, quality prioritisation and explicit dimensions raise exceptions and
            // are deliberately left alone.
            let bracketSettings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: 0,
                processedFormat: processedFormat(),
                bracketedSettings: bracketed
            )
            bracketSettings.isLensStabilizationEnabled =
                photoOutput.isLensStabilizationDuringBracketedCaptureSupported
            settings = bracketSettings
        } else {
            let single = AVCapturePhotoSettings(format: processedFormat())
            // Every one of these must be something the active camera actually advertises.
            if photoOutput.supportedFlashModes.contains(.off) {
                single.flashMode = .off
            }
            single.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
            settings = single
        }

        // A request that never calls back must not leave the shutter locked forever.
        let timeout = 6.0 + 3.0 * Double(exposures.count)

        return await withCheckedContinuation { continuation in
            let gate = CaptureResumeGate()
            let delegate = SequenceCaptureDelegate(
                requestedEVs: exposures,
                baseIndex: baseIndex,
                context: context
            ) { [weak self] outcome in
                gate.cancelWatchdog()
                guard gate.claim() else { return }
                Task { @MainActor [weak self] in
                    self?.captureDelegate = nil
                }
                continuation.resume(returning: outcome)
            }
            captureDelegate = delegate

            gate.watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, gate.claim() else { return }
                continuation.resume(returning: SegmentOutcome(failure: .bracketCaptureFailed))
            }

            sessionQueue.async { [photoOutput] in
                guard let connection = photoOutput.connection(with: .video),
                      connection.isActive, connection.isEnabled
                else {
                    gate.cancelWatchdog()
                    guard gate.claim() else { return }
                    continuation.resume(returning: SegmentOutcome(failure: .captureInterrupted))
                    return
                }
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                delegate.markRequestIssued()
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Holding the composition still

    /// Establishes focus, white balance and a stable, centre-metered EV 0 reference, then holds
    /// focus and white balance for the whole sequence.
    ///
    /// Exposure itself deliberately stays automatic: the bracket biases are relative to the
    /// camera's own metering, so locking it would risk nine identical frames instead of a real
    /// exposure ladder. The metering point is fixed at the centre and the reference is allowed to
    /// settle once — it is never re-metered per frame. Every wait has a short, measured ceiling.
    private func prepareForSequence(strategy calibration: CameraCalibrationProfile) async -> SequencePreparation {
        guard let device else { return .unavailable }
        let started = Date()
        let focusStrategy = calibration.focusStrategy
        let point = CGPoint(x: focusStrategy.pointX, y: focusStrategy.pointY)

        // Zoom is pinned to the physical lens: no digital zoom, and no change between frames.
        // The factor is clamped into the camera's own range — an out-of-range value is fatal.
        configure(device) { camera in
            let lowest = max(1.0, camera.minAvailableVideoZoomFactor)
            let target = min(lowest, camera.maxAvailableVideoZoomFactor)
            guard target >= camera.minAvailableVideoZoomFactor,
                  abs(camera.videoZoomFactor - target) > 0.001
            else { return }
            camera.videoZoomFactor = target
        }

        // 1–3: establish autofocus on the composition centre, let it settle, then lock it.
        var focusStatus = FocusStatus.unavailable
        var focusLock = LockOutcome.unsupported
        var focusTimeout = false
        if device.isFocusModeSupported(.autoFocus) {
            self.focusStatus = .searching
            configure(device) { camera in
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = point
                }
                camera.focusMode = .autoFocus
            }
            let settled = await settle(
                startWindow: 0.15,
                timeout: focusStrategy.settleTimeoutMs / 1000
            ) { [weak device] in device?.isAdjustingFocus ?? false }
            focusTimeout = !settled
            focusStatus = settled ? .ready : .failed
        }
        if device.isFocusModeSupported(.locked) {
            let locked = configure(device) { $0.focusMode = .locked }
            focusLock = locked ? .succeeded : .failed
            if locked { focusStatus = .locked } else if focusStatus != .unavailable { focusStatus = .failed }
        }
        self.focusStatus = focusStatus

        // White balance: let auto white balance settle, then lock it for the bracket.
        var whiteBalanceLock = LockOutcome.unsupported
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            configure(device) { $0.whiteBalanceMode = .autoWhiteBalance }
            await settle(timeout: calibration.whiteBalanceStrategy.settleTimeoutMs / 1000) { [weak device] in
                device?.isAdjustingWhiteBalance ?? false
            }
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            whiteBalanceLock = configure(device) { $0.whiteBalanceMode = .locked } ? .succeeded : .failed
        }
        let whiteBalanceReference = Self.whiteBalanceReading(device)

        // EV 0 reference: predictable centre metering, settled once, never re-metered per frame.
        configure(device) { camera in
            if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = point
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
        }
        let exposureSettled = await settle(timeout: calibration.exposureStrategy.settleTimeoutMs / 1000) { [weak device] in
            device?.isAdjustingExposure ?? false
        }

        return SequencePreparation(
            focusStatus: focusStatus,
            focusLock: focusLock,
            focusTimeout: focusTimeout,
            whiteBalanceLock: whiteBalanceLock,
            whiteBalanceReference: whiteBalanceReference,
            exposureReferenceEstablished: exposureSettled,
            meteringStrategy: calibration.exposureStrategy.metering,
            preparationMs: Date().timeIntervalSince(started) * 1000
        )
    }

    /// Returns the camera to normal behaviour once the sequence is over.
    private func restoreContinuousModes() {
        guard let device else { return }
        configure(device) { camera in
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
        focusStatus = device.isFocusModeSupported(.autoFocus) ? .ready : .unavailable
    }

    @discardableResult
    private func configure(_ device: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            body(device)
            return true
        } catch {
            return false
        }
    }

    /// Waits — briefly and with a hard ceiling — for the camera to stop adjusting.
    ///
    /// `startWindow` gives a just-triggered adjustment (an autofocus scan) a moment to begin, so
    /// a scan that has not started yet is not mistaken for one that already finished.
    /// - Returns: `true` when the camera settled, `false` on timeout.
    @discardableResult
    private func settle(
        startWindow: TimeInterval = 0,
        timeout: TimeInterval,
        while isAdjusting: @escaping () -> Bool
    ) async -> Bool {
        let begin = Date()
        if startWindow > 0 {
            let startDeadline = begin.addingTimeInterval(startWindow)
            while !isAdjusting(), Date() < startDeadline {
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
        let deadline = begin.addingTimeInterval(max(timeout, startWindow))
        while isAdjusting(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !isAdjusting()
    }

    /// Current white balance as raw gains plus temperature/tint — only on cameras that expose
    /// white balance control, and only through conversions they accept.
    nonisolated static func whiteBalanceReading(_ device: AVCaptureDevice) -> WhiteBalanceReading? {
        guard device.isWhiteBalanceModeSupported(.locked) else { return nil }
        let gains = device.deviceWhiteBalanceGains
        guard gains.redGain > 0, gains.greenGain > 0, gains.blueGain > 0 else { return nil }
        var reading = WhiteBalanceReading(
            redGain: Double(gains.redGain),
            greenGain: Double(gains.greenGain),
            blueGain: Double(gains.blueGain)
        )
        let maxGain = device.maxWhiteBalanceGain
        if maxGain >= 1 {
            // Conversion only accepts gains inside 1…max; anything else is a fatal exception.
            func clamp(_ value: Float) -> Float { min(maxGain, max(1, value)) }
            let normalized = AVCaptureDevice.WhiteBalanceGains(
                redGain: clamp(gains.redGain),
                greenGain: clamp(gains.greenGain),
                blueGain: clamp(gains.blueGain)
            )
            let values = device.temperatureAndTintValues(for: normalized)
            reading.temperature = Double(values.temperature)
            reading.tint = Double(values.tint)
        }
        return reading
    }

    func clearFailure() {
        failure = nil
    }
}

// MARK: - Capture delegate

/// Reads live lens and white-balance state while frames arrive, off the main actor.
/// Read-only access to KVO-backed device properties.
nonisolated final class DeviceProbe: @unchecked Sendable {
    private let device: AVCaptureDevice

    init(_ device: AVCaptureDevice) {
        self.device = device
    }

    var lensPosition: Double? {
        device.isFocusModeSupported(.autoFocus) ? Double(device.lensPosition) : nil
    }

    func whiteBalance() -> WhiteBalanceReading? {
        CameraService.whiteBalanceReading(device)
    }
}

/// Sendable description of the camera at the moment of capture, handed to the delegate so each
/// frame it writes is fully described without touching the main actor.
private struct SequenceContext: Sendable {
    var clientCaptureID: UUID
    var orientation: CaptureOrientation
    var cameraID: String
    var lensType: String
    var isBracket: Bool
    var probe: DeviceProbe
}

private struct SegmentOutcome: Sendable {
    var frames: [CaptureFrame] = []
    var persistSeconds: Double = 0
    var firstPhotoAt: Date?
    var lastPhotoAt: Date?
    /// Normalised failure. Frames already written are still reported, as evidence.
    var failure: CameraError?
    /// The native request actually reached `capturePhoto`.
    var requestIssued: Bool = false
    /// Every `didFinishProcessingPhoto` callback, successful or not.
    var callbacks: Int = 0
    var callbackErrors: Int = 0
    /// Callbacks that resolved to a ladder position already written.
    var indexCollisions: Int = 0
}

/// Guarantees one capture request resolves exactly once, whether it is the camera or the
/// watchdog that finishes it.
private final class CaptureResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var watchdogTask: Task<Void, Never>?

    var watchdog: Task<Void, Never>? {
        get { lock.withLock { watchdogTask } }
        set { lock.withLock { watchdogTask = newValue } }
    }

    /// Returns true to exactly one caller.
    func claim() -> Bool {
        lock.withLock {
            if isResolved { return false }
            isResolved = true
            return true
        }
    }

    func cancelWatchdog() {
        let task = lock.withLock { watchdogTask }
        task?.cancel()
    }
}

/// Bridges AVFoundation's bracketed capture callbacks to `async`/`await`.
///
/// Each exposure is written to disk the moment it arrives — the image data is released
/// immediately afterwards, so a nine-frame bracket never accumulates in memory. The requested EV
/// is taken from the bracket settings AVFoundation hands back, never from callback order alone.
private nonisolated final class SequenceCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let requestedEVs: [Double]
    private let baseIndex: Int
    private let context: SequenceContext
    private let completion: @Sendable (SegmentOutcome) -> Void

    private var outcome = SegmentOutcome()
    private var received = 0
    private var hasFinished = false
    private var usedIndexes: Set<Int> = []

    init(
        requestedEVs: [Double],
        baseIndex: Int,
        context: SequenceContext,
        completion: @escaping @Sendable (SegmentOutcome) -> Void
    ) {
        self.requestedEVs = requestedEVs
        self.baseIndex = baseIndex
        self.context = context
        self.completion = completion
    }

    func markRequestIssued() {
        outcome.requestIssued = true
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !hasFinished else { return }
        outcome.callbacks += 1

        if error != nil {
            outcome.callbackErrors += 1
            outcome.failure = context.isBracket ? .bracketCaptureFailed : .captureFailed
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            outcome.callbackErrors += 1
            outcome.failure = context.isBracket ? .bracketCaptureFailed : .captureFailed
            return
        }

        let arrivedAt = Date()
        if outcome.firstPhotoAt == nil { outcome.firstPhotoAt = arrivedAt }
        outcome.lastPhotoAt = arrivedAt

        // Lens and colour state are sampled the moment each exposure arrives, so a focus or white
        // balance drift between frames is measurable afterwards.
        let lensPosition = context.probe.lensPosition
        let whiteBalance = context.probe.whiteBalance()

        // Position in the ladder comes from the settings AVFoundation echoes back, so the bracket
        // can be reconstructed deterministically even if callbacks arrive out of order.
        let bracketBias = (photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings)?
            .exposureTargetBias
        // `sequenceCount` is AVFoundation's own 1-based position inside this request.
        let reportedPosition = photo.sequenceCount >= 1 ? photo.sequenceCount - 1 : received
        let fallbackPosition = min(reportedPosition, max(0, requestedEVs.count - 1))
        let requestedEV = bracketBias.map { Double($0) } ?? requestedEVs[fallbackPosition]
        let ladderPosition = requestedEVs.firstIndex { abs($0 - requestedEV) < 0.01 } ?? fallbackPosition
        let sequenceIndex = baseIndex + ladderPosition

        // Two callbacks resolving to the same position would overwrite one file with another and
        // make one real exposure disappear. That is recorded and the attempt fails — never hidden.
        guard !usedIndexes.contains(sequenceIndex) else {
            outcome.indexCollisions += 1
            outcome.failure = .duplicateFrame
            received += 1
            return
        }
        usedIndexes.insert(sequenceIndex)

        let metadata = Self.exposureMetadata(photo)
        let timestamp = CMTimeGetSeconds(photo.timestamp)
        let writeStartedAt = Date()
        do {
            var frame = try CaptureBundleStore.writeFrame(
                photoData: data,
                clientCaptureID: context.clientCaptureID,
                sequenceIndex: sequenceIndex,
                requestedEV: requestedEV,
                orientation: context.orientation,
                cameraID: context.cameraID,
                lensType: context.lensType,
                capturedAt: arrivedAt
            )
            frame.actualExposureBias = metadata.bias
            frame.exposureDurationSeconds = metadata.exposureDuration
            frame.iso = metadata.iso
            frame.aperture = metadata.aperture
            frame.focalLengthMM = metadata.focalLength
            frame.lensPosition = lensPosition
            frame.whiteBalance = whiteBalance
            frame.sensorTimestampSeconds = timestamp.isFinite && timestamp > 0 ? timestamp : nil
            frame.metadata = metadata.extras
            outcome.frames.append(frame)
        } catch {
            outcome.failure = .frameSaveFailed
        }
        outcome.persistSeconds += Date().timeIntervalSince(writeStartedAt)
        received += 1
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard !hasFinished else { return }
        hasFinished = true

        if error != nil, outcome.failure == nil {
            outcome.failure = context.isBracket ? .bracketCaptureFailed : .captureFailed
        }
        completion(outcome)
    }

    /// Reads what the camera actually did, rather than what was asked of it.
    private static func exposureMetadata(
        _ photo: AVCapturePhoto
    ) -> (
        bias: Double?,
        exposureDuration: Double?,
        iso: Double?,
        aperture: Double?,
        focalLength: Double?,
        extras: [String: String]
    ) {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let bias = exif?[kCGImagePropertyExifExposureBiasValue as String] as? Double
        let duration = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first
        let aperture = exif?[kCGImagePropertyExifFNumber as String] as? Double
        let focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double

        var extras: [String: String] = [:]
        if let lensModel = exif?[kCGImagePropertyExifLensModel as String] as? String {
            extras["lensModel"] = lensModel
        }
        if let focalLength35 = exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double {
            extras["focalLength35mm"] = String(Int(focalLength35))
        }
        if let brightness = exif?[kCGImagePropertyExifBrightnessValue as String] as? Double {
            extras["brightnessValue"] = String(format: "%.3f", brightness)
        }
        extras["photoCount"] = String(photo.photoCount)
        extras["sequenceCount"] = String(photo.sequenceCount)
        return (bias, duration, iso, aperture, focalLength, extras)
    }
}
