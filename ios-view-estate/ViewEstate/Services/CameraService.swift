import AVFoundation
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
    var focusLock: LockOutcome
    var whiteBalanceLock: LockOutcome
    var startedAt: Date
    var completedAt: Date
    /// Real measurements, in seconds.
    var firstFrameSeconds: Double?
    var bracketSeconds: Double
    var persistSeconds: Double

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
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    /// AVFoundation only holds its delegate for the duration of a capture; keep it alive here.
    private var captureDelegate: SequenceCaptureDelegate?
    private var captureRotationAngle: CGFloat = 90
    private var interruptionObservers: [NSObjectProtocol] = []
    /// Set by a session interruption, a runtime error or the app leaving the foreground.
    private var interruptionFlag = false
    private var isCaptureInFlight = false

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
    func start() async {
        let access = await requestAccess()
        guard access.isAuthorized else { return }

        if !isConfigured {
            do {
                try await configure()
                isConfigured = true
                failure = nil
            } catch {
                let normalized = (error as? CameraError) ?? .initializationFailed
                failure = normalized
                VELog.cameraError(normalized.code, "configuration")
                return
            }
        }

        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
        isRunning = session.isRunning
        applyRotationAngles()
        // Bracket size depends on the running session's preset and active format, so capabilities
        // are only meaningful once the camera is actually live.
        readCapabilities()
    }

    /// Stops the session when the camera leaves the screen or the app goes to the background.
    func stop() {
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

    /// Binds the preview layer so rotation stays level with gravity in every orientation.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        guard let device else { return }
        makeRotationCoordinator(for: device)
    }

    deinit {
        for observer in interruptionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    private func configure() async throws {
        guard let device = Self.preferredCamera() else {
            throw CameraError.initializationFailed
        }
        self.device = device

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
                // The base supported dimension is deliberate: it is the resolution bracketed
                // capture supports, it keeps all nine frames identical, and a nine-frame bracket
                // at maximum dimensions would be a memory risk for no HDR benefit.
                if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.first {
                    photoOutput.maxPhotoDimensions = dimensions
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }

        videoInput = input
        makeRotationCoordinator(for: device)
        setup = Self.describe(device)
        observeInterruptions()
        VELog.camera("session configured device=\(device.localizedName) preset=photo")
    }

    /// The main rear camera. Lenses are never switched automatically: a single physical device is
    /// chosen once, so no frame of a bracket can come from a different lens.
    /// External devices are included so an injected camera is found when no built-in one exists.
    private static func preferredCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        return devices.first { $0.position == .back }
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
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
    private static func deviceModelName() -> String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        let identifier = withUnsafeBytes(of: machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
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
        plan = CaptureProfileService.plan(for: detected)
        VELog.camera(
            "capabilities bias=\(detected.minExposureBias)…\(detected.maxExposureBias) "
                + "maxBracket=\(detected.maxBracketCount) profile=\(plan.profile.devLabel) "
                + "segments=\(plan.segments.count)"
        )
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        guard interruptionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.runtimeErrorNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markInterrupted()
                    VELog.camera("session event \(name.rawValue) duringCapture=\(self.isCaptureInFlight)")
                }
            }
            interruptionObservers.append(observer)
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
    /// white balance locked where the hardware allows it, one orientation captured up front, and
    /// exposure varied only by the requested bias relative to a settled EV 0 reference. Frames are
    /// written to the capture bundle as they arrive, so the device never holds the whole bracket
    /// in memory.
    ///
    /// - Throws: `BracketCaptureFailure` carrying a normalised code and whatever was persisted.
    func captureBracket(clientCaptureID: UUID) async throws -> BracketCaptureResult {
        guard access.isAuthorized else {
            throw BracketCaptureFailure(code: .permissionDenied, partial: emptyResult(clientCaptureID))
        }
        guard isConfigured, session.isRunning, let device else {
            throw BracketCaptureFailure(code: .initializationFailed, partial: emptyResult(clientCaptureID))
        }

        let plan = self.plan
        let startedAt = Date()
        // Orientation is decided once, at the top of the attempt: rotating the phone mid-bracket
        // never gives individual frames different orientations.
        let angle = captureRotationAngle
        let orientation = CaptureOrientation(videoRotationAngle: angle)
        let cameraID = device.uniqueID
        let lensType = Self.lensLabel(device)

        interruptionFlag = false
        isCaptureInFlight = true
        defer { isCaptureInFlight = false }

        let locks = await prepareForSequence()
        var frames: [CaptureFrame] = []
        var persistSeconds: Double = 0
        var firstPhotoAt: Date?
        var failureCode: CameraError?

        segments: for segment in plan.segments {
            if interruptionFlag {
                failureCode = .captureInterrupted
                break segments
            }

            let baseIndex = frames.count
            let outcome = await captureSegment(
                exposures: segment,
                baseIndex: baseIndex,
                rotationAngle: angle,
                context: SequenceContext(
                    clientCaptureID: clientCaptureID,
                    orientation: orientation,
                    cameraID: cameraID,
                    lensType: lensType,
                    lensPosition: Double(device.lensPosition),
                    isBracket: plan.profile.isBracket
                )
            )

            frames.append(contentsOf: outcome.frames)
            persistSeconds += outcome.persistSeconds
            if firstPhotoAt == nil { firstPhotoAt = outcome.firstPhotoAt }

            if let code = outcome.failure {
                failureCode = code
                break segments
            }
            if outcome.frames.count != segment.count {
                failureCode = .frameMissing
                break segments
            }
        }

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
            focusLock: locks.focus,
            whiteBalanceLock: locks.whiteBalance,
            startedAt: startedAt,
            completedAt: completedAt,
            firstFrameSeconds: firstPhotoAt.map { $0.timeIntervalSince(startedAt) },
            bracketSeconds: completedAt.timeIntervalSince(startedAt),
            persistSeconds: persistSeconds
        )

        if interruptionFlag { failureCode = .captureInterrupted }
        if failureCode == nil, !result.isComplete { failureCode = .frameMissing }

        if let failureCode {
            failure = failureCode
            VELog.cameraError(
                failureCode.code,
                "profile=\(plan.profile.devLabel) frames=\(frames.count)/\(plan.expectedFrameCount)"
            )
            throw BracketCaptureFailure(code: failureCode, partial: result)
        }

        failure = nil
        VELog.camera(
            "bracket \(plan.profile.devLabel) frames=\(result.frames.count) "
                + "in \(String(format: "%.2f", result.bracketSeconds))s "
                + "focusLock=\(locks.focus.devLabel) wbLock=\(locks.whiteBalance.devLabel)"
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
            focusLock: .unsupported,
            whiteBalanceLock: .unsupported,
            startedAt: now,
            completedAt: now,
            firstFrameSeconds: nil,
            bracketSeconds: 0,
            persistSeconds: 0
        )
    }

    /// One native capture request: a bracket of up to `maxBracketCount` exposures, or a single
    /// photograph when the camera cannot bracket at all.
    private func captureSegment(
        exposures: [Int],
        baseIndex: Int,
        rotationAngle: CGFloat,
        context: SequenceContext
    ) async -> SegmentOutcome {
        await withCheckedContinuation { continuation in
            let settings: AVCapturePhotoSettings
            if context.isBracket, exposures.count >= 1, plan.profile.isBracket {
                let bracketed = exposures.map {
                    AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                        exposureTargetBias: Float($0)
                    )
                }
                // Bracketed capture only supports a small set of inherited settings — flash,
                // stabilisation and quality prioritisation raise exceptions and are left alone.
                let bracketSettings = AVCapturePhotoBracketSettings(
                    rawPixelFormatType: 0,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
                    bracketedSettings: bracketed
                )
                bracketSettings.isLensStabilizationEnabled =
                    photoOutput.isLensStabilizationDuringBracketedCaptureSupported
                settings = bracketSettings
            } else {
                let single = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                single.flashMode = .off
                single.photoQualityPrioritization = .quality
                single.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                settings = single
            }

            let delegate = SequenceCaptureDelegate(
                requestedEVs: exposures,
                baseIndex: baseIndex,
                context: context
            ) { [weak self] outcome in
                Task { @MainActor [weak self] in
                    self?.captureDelegate = nil
                }
                continuation.resume(returning: outcome)
            }
            captureDelegate = delegate

            sessionQueue.async { [photoOutput] in
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Holding the composition still

    /// Establishes focus, white balance and a stable EV 0 reference, then holds them.
    ///
    /// Exposure itself deliberately stays automatic: the bracket biases are relative to the
    /// camera's own metering, so locking it would risk nine identical frames instead of a real
    /// exposure ladder. What must not drift — focus and white balance — is locked.
    private func prepareForSequence() async -> (focus: LockOutcome, whiteBalance: LockOutcome) {
        guard let device else { return (.unsupported, .unsupported) }

        // Zoom is pinned to the physical lens: no digital zoom, and no change between frames.
        configure(device) { camera in
            let minimum = camera.minAvailableVideoZoomFactor
            camera.videoZoomFactor = max(1.0, minimum)
        }

        var focus = LockOutcome.unsupported
        if device.isFocusModeSupported(.autoFocus) {
            configure(device) { camera in
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                camera.focusMode = .autoFocus
            }
            await settle { [weak device] in device?.isAdjustingFocus ?? false }
        }
        if device.isFocusModeSupported(.locked) {
            focus = configure(device) { $0.focusMode = .locked } ? .succeeded : .failed
        }

        var whiteBalance = LockOutcome.unsupported
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            configure(device) { $0.whiteBalanceMode = .autoWhiteBalance }
            await settle { [weak device] in device?.isAdjustingWhiteBalance ?? false }
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            whiteBalance = configure(device) { $0.whiteBalanceMode = .locked } ? .succeeded : .failed
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            configure(device) { $0.exposureMode = .continuousAutoExposure }
        }
        await settle { [weak device] in device?.isAdjustingExposure ?? false }

        return (focus, whiteBalance)
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
    private func settle(
        timeout: TimeInterval = 1.2,
        while isAdjusting: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isAdjusting(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func clearFailure() {
        failure = nil
    }
}

// MARK: - Capture delegate

/// Sendable description of the camera at the moment of capture, handed to the delegate so each
/// frame it writes is fully described without touching the main actor.
private struct SequenceContext: Sendable {
    var clientCaptureID: UUID
    var orientation: CaptureOrientation
    var cameraID: String
    var lensType: String
    var lensPosition: Double?
    var isBracket: Bool
}

private struct SegmentOutcome: Sendable {
    var frames: [CaptureFrame] = []
    var persistSeconds: Double = 0
    var firstPhotoAt: Date?
    /// Normalised failure. Frames already written are still reported, as evidence.
    var failure: CameraError?
}

/// Bridges AVFoundation's bracketed capture callbacks to `async`/`await`.
///
/// Each exposure is written to disk the moment it arrives — the image data is released
/// immediately afterwards, so a nine-frame bracket never accumulates in memory. The requested EV
/// is taken from the bracket settings AVFoundation hands back, never from callback order alone.
private nonisolated final class SequenceCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let requestedEVs: [Int]
    private let baseIndex: Int
    private let context: SequenceContext
    private let completion: @Sendable (SegmentOutcome) -> Void

    private var outcome = SegmentOutcome()
    private var received = 0
    private var hasFinished = false

    init(
        requestedEVs: [Int],
        baseIndex: Int,
        context: SequenceContext,
        completion: @escaping @Sendable (SegmentOutcome) -> Void
    ) {
        self.requestedEVs = requestedEVs
        self.baseIndex = baseIndex
        self.context = context
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !hasFinished else { return }

        if error != nil {
            outcome.failure = context.isBracket ? .bracketCaptureFailed : .captureFailed
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            outcome.failure = context.isBracket ? .bracketCaptureFailed : .captureFailed
            return
        }

        if outcome.firstPhotoAt == nil { outcome.firstPhotoAt = Date() }

        // Position in the ladder comes from the settings AVFoundation echoes back, so the bracket
        // can be reconstructed deterministically even if callbacks arrive out of order.
        let bracketBias = (photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings)?
            .exposureTargetBias
        let fallbackEV = requestedEVs[min(received, max(0, requestedEVs.count - 1))]
        let requestedEV = bracketBias.map { Double($0) } ?? Double(fallbackEV)
        let ladderPosition = requestedEVs.firstIndex { abs(Double($0) - requestedEV) < 0.01 } ?? received
        let sequenceIndex = baseIndex + ladderPosition

        let metadata = Self.exposureMetadata(photo)
        let writeStartedAt = Date()
        do {
            var frame = try CaptureBundleStore.writeFrame(
                photoData: data,
                clientCaptureID: context.clientCaptureID,
                sequenceIndex: sequenceIndex,
                requestedEV: requestedEV,
                orientation: context.orientation,
                cameraID: context.cameraID,
                lensType: context.lensType
            )
            frame.actualExposureBias = metadata.bias
            frame.exposureDurationSeconds = metadata.exposureDuration
            frame.iso = metadata.iso
            frame.aperture = metadata.aperture
            frame.lensPosition = context.lensPosition
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
    ) -> (bias: Double?, exposureDuration: Double?, iso: Double?, aperture: Double?, extras: [String: String]) {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let bias = exif?[kCGImagePropertyExifExposureBiasValue as String] as? Double
        let duration = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first
        let aperture = exif?[kCGImagePropertyExifFNumber as String] as? Double

        var extras: [String: String] = [:]
        if let lensModel = exif?[kCGImagePropertyExifLensModel as String] as? String {
            extras["lensModel"] = lensModel
        }
        if let focalLength = exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double {
            extras["focalLength35mm"] = String(Int(focalLength))
        }
        if let brightness = exif?[kCGImagePropertyExifBrightnessValue as String] as? Double {
            extras["brightnessValue"] = String(format: "%.3f", brightness)
        }
        extras["photoCount"] = String(photo.photoCount)
        extras["sequenceCount"] = String(photo.sequenceCount)
        return (bias, duration, iso, aperture, extras)
    }
}
