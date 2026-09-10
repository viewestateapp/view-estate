import AVFoundation
import Observation
import UIKit

/// Native camera for the capture flow: real rear camera preview and one real photograph per
/// shutter action.
///
/// This service owns the AVFoundation session and nothing else. It never registers captures,
/// never touches the portfolio and never decides idempotency — that stays in `AppState`, keyed on
/// the capture attempt. Bracketing, HDR merge and any processing are deliberately absent: this
/// phase only proves that a single photograph can be captured, oriented and stored reliably.
@Observable
final class CameraService {
    // MARK: - Observable state

    private(set) var access: CameraAccess = .unknown
    private(set) var isRunning: Bool = false
    private(set) var setup: CameraSetup?
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
    private var captureDelegate: PhotoCaptureDelegate?
    private var captureRotationAngle: CGFloat = 90

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
    }

    /// Stops the session when the camera leaves the screen or the app goes to the background.
    func stop() {
        guard isConfigured else { return }
        isRunning = false
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Binds the preview layer so rotation stays level with gravity in every orientation.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        guard let device else { return }
        makeRotationCoordinator(for: device)
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
                // so the preview is never stretched.
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
                if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
                    photoOutput.maxPhotoDimensions = dimensions
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }

        videoInput = input
        makeRotationCoordinator(for: device)
        setup = Self.describe(device)
        VELog.camera("session configured device=\(device.localizedName) preset=photo")
    }

    /// The main rear camera. Lenses are never switched automatically.
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
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last
        let resolution = dimensions.map { "\($0.width) × \($0.height)" } ?? "—"
        return CameraSetup(
            deviceName: UIDevice.current.model + " · " + device.localizedName,
            deviceID: device.uniqueID,
            lens: Self.lensLabel(device),
            captureResolution: resolution
        )
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

    /// Captures ONE real photograph and stores it inside the app container.
    ///
    /// The file is named after the shutter action (`clientCaptureID`), so a repeated completion
    /// event for the same attempt resolves to the same file instead of a duplicate.
    ///
    /// - Throws: `CameraError` — already normalised, safe to show as friendly copy.
    func capturePhoto(clientCaptureID: UUID) async throws -> (file: LocalPhotoFile, seconds: Double) {
        guard access.isAuthorized else { throw CameraError.permissionDenied }
        guard isConfigured, session.isRunning else { throw CameraError.initializationFailed }

        let startedAt = Date()
        let angle = captureRotationAngle
        let photoData = try await capturePhotoData(rotationAngle: angle)
        let orientation = CaptureOrientation(videoRotationAngle: angle)

        let file: LocalPhotoFile
        do {
            file = try await Task.detached(priority: .userInitiated) {
                try CaptureFileStore.saveOriginal(
                    photoData: photoData,
                    clientCaptureID: clientCaptureID,
                    orientation: orientation
                )
            }.value
        } catch {
            let normalized = (error as? CameraError) ?? .localSaveFailed
            failure = normalized
            VELog.cameraError(normalized.code, "bytes=\(photoData.count)")
            throw normalized
        }

        let seconds = Date().timeIntervalSince(startedAt)
        failure = nil
        VELog.camera(
            "captured \(file.pixelDescription) orientation=\(orientation.devLabel) "
                + "bytes=\(file.byteCount) in \(String(format: "%.2f", seconds))s"
        )
        return (file, seconds)
    }

    private func capturePhotoData(rotationAngle: CGFloat) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                settings.photoQualityPrioritization = .quality
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.captureDelegate = nil
                    }
                    continuation.resume(with: result)
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
        } catch {
            let normalized = (error as? CameraError) ?? .captureFailed
            failure = normalized
            VELog.cameraError(normalized.code, "photo output")
            throw normalized
        }
    }

    func clearFailure() {
        failure = nil
    }
}

/// Bridges the AVFoundation delegate callbacks to `async`/`await`. Runs off the main actor and
/// resumes exactly once, whatever the outcome.
private nonisolated final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var hasFinished = false

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !hasFinished else { return }
        hasFinished = true

        if error != nil {
            completion(.failure(CameraError.captureFailed))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(CameraError.captureFailed))
            return
        }
        completion(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error != nil, !hasFinished else { return }
        hasFinished = true
        completion(.failure(CameraError.captureFailed))
    }
}
