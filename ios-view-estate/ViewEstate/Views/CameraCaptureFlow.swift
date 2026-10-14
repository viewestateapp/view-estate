import SwiftUI

/// Capture experience presented full screen: the viewfinder prototype and, once a
/// sequence finishes, the short confirmation that sends the user straight back to shooting.
/// The internal preparation pipeline is never surfaced here.
struct CameraCaptureFlow: View {
    let property: Property
    let initialRoom: RoomType
    /// Development preview only: keeps the shutter in its capturing state.
    var previewCapturing: Bool = false

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var room: RoomType
    @State private var completedCapture: CaptureItem?
    @State private var showRoomPicker = false

    init(property: Property, initialRoom: RoomType, previewCapturing: Bool = false) {
        self.property = property
        self.initialRoom = initialRoom
        self.previewCapturing = previewCapturing
        _room = State(initialValue: initialRoom)
    }

    var body: some View {
        ZStack {
            CameraPrototypeView(
                property: property,
                room: $room,
                previewCapturing: previewCapturing,
                onCaptured: { attempt, outcome in
                    let capture = state.registerCapture(
                        attempt: attempt,
                        property: property,
                        room: attempt.room,
                        frameCount: outcome.frameCount,
                        localFile: outcome.localFile,
                        manifest: outcome.manifest
                    )
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        completedCapture = capture
                    }
                },
                onClose: { dismiss() }
            )

            if let capture = completedCapture {
                CaptureCompletedView(
                    capture: capture,
                    property: property,
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.25)) { completedCapture = nil }
                    },
                    onNextRoom: {
                        showRoomPicker = true
                    },
                    onClose: { dismiss() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .sheet(isPresented: $showRoomPicker) {
            NavigationStack {
                RoomPickerContent(
                    property: property,
                    suggested: state.nextRoom(after: room, in: property),
                    currentRoom: room
                ) { picked in
                    room = picked
                    showRoomPicker = false
                    withAnimation(.easeInOut(duration: 0.25)) { completedCapture = nil }
                }
                .navigationTitle(state.t("capture.pick.room"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(state.t("common.cancel")) { showRoomPicker = false }
                            .foregroundStyle(VE.textSecondary)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
    }
}

/// Everything one finished shutter action hands back to the capture flow.
struct CaptureOutcome: Sendable {
    var frameCount: Int
    /// The reference exposure (EV 0) of a real bracket.
    var localFile: LocalPhotoFile?
    /// Local record of every real exposure. Absent for the simulated prototype.
    var manifest: CaptureManifest?
}

/// The professional capture tool.
///
/// The interface is the approved one in both modes. With `camera_native_enabled` OFF the
/// viewfinder is a faithful UI simulation; with it ON the real rear camera runs behind exactly
/// the same interface and one shutter tap photographs a real multi-exposure bracket.
struct CameraPrototypeView: View {
    let property: Property
    @Binding var room: RoomType
    var previewCapturing: Bool = false
    /// Delivers the finished capture together with the attempt that produced it.
    let onCaptured: (CaptureAttempt, CaptureOutcome) -> Void
    let onClose: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = CameraService()
    /// Real device motion: drives the stability chip, the level line and the shutter policy.
    @State private var stability = CameraStabilityService()
    @State private var isCapturing = false
    @State private var activeFrame: Double?
    @State private var shutterPulse = false
    @State private var errorMessage: String?

    /// The prototype always shows the full ladder; profiles are a real-camera concern.
    private let simulatedExposures: [Double] = CaptureProfile.full9.exposureValues

    /// In native mode the ladder is whatever this device can genuinely photograph.
    private var exposures: [Double] {
        isNative ? camera.plan.exposureValues : simulatedExposures
    }

    private var stabilityState: StabilityState { stability.displayState }
    private var isStable: Bool { stabilityState == .stable }

    /// Horizon tilt shown by the level line, kept subtle.
    private var levelAngle: Double {
        guard stability.isSensorAvailable else { return 0 }
        return min(20, max(-20, stability.reading.rollDegrees))
    }

    private var isLevel: Bool {
        !stability.isSensorAvailable || stability.reading.isLevel
    }

    private var isNative: Bool {
        state.cameraMode.isNative && !previewCapturing
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            viewfinder
            roomChips
            controls
        }
        .background(VE.overlay.ignoresSafeArea())
        .onAppear { stability.start() }
        .task {
            guard previewCapturing else { return }
            while !Task.isCancelled {
                await animateBracket()
            }
        }
        .task(id: isNative) {
            guard isNative else { return }
            await startCamera()
            if let failure = camera.failure, failure != .permissionDenied {
                errorMessage = state.t(failure.localizationKey)
                state.cameraDiagnostics.lastErrorCode = failure.code
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                stability.start()
                if isNative { Task { await startCamera() } }
            case .background, .inactive:
                stability.stop()
                guard isNative else { return }
                // A sequence that loses the foreground can never be completed as a success.
                camera.markInterrupted()
                camera.stop()
            @unknown default:
                break
            }
        }
        .onDisappear {
            camera.stop()
            stability.stop()
        }
    }

    // MARK: - Context

    private var contextBar: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(VE.surface, in: .circle)
            }
            .accessibilityLabel(state.t("common.close"))

            VStack(alignment: .leading, spacing: 1) {
                Text(property.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.roomName(room))
                    .font(VE.Font.caption)
                    .foregroundStyle(VE.copper)
            }

            Spacer()

            statusChip(
                text: isCapturing ? state.t("camera.capturing") : state.t("camera.ready"),
                tint: isCapturing ? VE.copper : (isCameraLive ? VE.success : VE.textSecondary),
                filled: true
            )
            if !state.isOnline {
                statusChip(text: state.t("camera.offline"), tint: VE.warning, filled: false)
            } else {
                statusChip(
                    text: state.t(stabilityState.localizationKey),
                    tint: isStable ? VE.textSecondary : VE.warning,
                    filled: false
                )
                .animation(.easeOut(duration: 0.2), value: stabilityState)
            }
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, VE.Space.s)
    }

    private func statusChip(text: String, tint: Color, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filled ? VE.textPrimary : tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VE.surface, in: .capsule)
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - VE.Space.m * 2
            let height = width * 4 / 3

            VStack(spacing: 8) {
                exposureStrip
                    .frame(width: width)

                Color.black
                    .frame(width: width, height: height)
                    .overlay { viewfinderContent }
                    .overlay { framingGuides }
                    .overlay { levelIndicator(width: width) }
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isCapturing ? VE.copper.opacity(0.6) : VE.border, lineWidth: 1)
                    }
                    .accessibilityLabel("\(state.t("camera.prototype")) 4:3")
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, VE.Space.m)
    }

    /// The live rear camera in native mode, the reference frame in simulated mode, and a
    /// friendly explanation when iOS is holding camera access back.
    @ViewBuilder
    private var viewfinderContent: some View {
        if isNative, camera.access.needsSystemSettings {
            permissionState
        } else if isNative {
            CameraPreview(service: camera)
                .allowsHitTesting(false)
                .overlay {
                    if !camera.isRunning {
                        ProgressView()
                            .tint(VE.textSecondary)
                    }
                }
        } else {
            Image(room.placeholderImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(frameBrightness)
                .allowsHitTesting(false)
        }
    }

    private var permissionState: some View {
        VStack(spacing: VE.Space.m) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VE.textSecondary)
            VStack(spacing: 6) {
                Text(state.t("camera.permission.title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("camera.permission.body"))
                    .font(VE.Font.body)
                    .foregroundStyle(VE.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                camera.openSystemSettings()
            } label: {
                Text(state.t("camera.permission.cta"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.copper)
                    .padding(.horizontal, VE.Space.m)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().strokeBorder(VE.copper.opacity(0.5), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera.openSettings")
        }
        .padding(VE.Space.l)
    }

    /// Advanced, ignorable technical information: a hairline exposure ladder.
    private var exposureStrip: some View {
        HStack(spacing: 0) {
            ForEach(exposures, id: \.self) { value in
                let active = activeFrame == value
                VStack(spacing: 3) {
                    Text(CaptureProfile.evLabel(value))
                        .font(VE.Font.mono)
                        .foregroundStyle(active ? VE.copper : (value == 0 ? VE.textSecondary : VE.textTertiary))
                    Rectangle()
                        .fill(active ? VE.copper : VE.textTertiary.opacity(0.4))
                        .frame(width: 1, height: value == 0 ? 8 : 5)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.12), value: activeFrame)
            }

            Text(exposures.count > 1 ? "HDR · \(exposures.count)" : "FOTO · 1")
                .font(VE.Font.mono)
                .foregroundStyle(VE.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(VE.surface, in: .capsule)
        }
        .accessibilityHidden(true)
    }

    private var framingGuides: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let length: CGFloat = 22

            Path { path in
                // Corner ticks
                path.move(to: CGPoint(x: 0, y: length)); path.addLine(to: .zero); path.addLine(to: CGPoint(x: length, y: 0))
                path.move(to: CGPoint(x: w - length, y: 0)); path.addLine(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: w, y: length))
                path.move(to: CGPoint(x: w, y: h - length)); path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: w - length, y: h))
                path.move(to: CGPoint(x: length, y: h)); path.addLine(to: CGPoint(x: 0, y: h)); path.addLine(to: CGPoint(x: 0, y: h - length))
            }
            .stroke(VE.textPrimary.opacity(0.85), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }

    /// Real horizon line: counter-rotates against the phone's roll, so it stays parallel to the
    /// true horizon. Within the calibrated tolerance it reads as ready; outside it, it guides.
    /// The source image is never rotated.
    private func levelIndicator(width: CGFloat) -> some View {
        Rectangle()
            .fill(isLevel ? VE.textPrimary.opacity(0.9) : VE.warning)
            .frame(width: width * 0.55, height: 1.5)
            .rotationEffect(.degrees(-levelAngle))
            .animation(.easeOut(duration: 0.12), value: levelAngle)
            .animation(.easeOut(duration: 0.2), value: isLevel)
            .allowsHitTesting(false)
    }

    private var frameBrightness: Double {
        guard let frame = activeFrame else { return 0.62 }
        return min(1.0, max(0.12, 0.62 + frame * 0.11))
    }

    // MARK: - Rooms

    private var roomChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(availableRooms) { item in
                    let active = room == item
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { room = item }
                    } label: {
                        Text(state.roomName(item))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(active ? VE.copper : VE.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                Capsule().fill(active ? VE.copper.opacity(0.16) : VE.surface)
                                Capsule().strokeBorder(active ? VE.copper.opacity(0.5) : .clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCapturing)
                    .accessibilityAddTraits(active ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, VE.Space.m)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, VE.Space.s)
    }

    private var availableRooms: [RoomType] {
        property.rooms.isEmpty ? RoomPresets.fallback : property.rooms
    }

    // MARK: - Controls

    private var isCameraLive: Bool {
        isNative ? camera.isRunning : true
    }

    /// CAMERA_READY plus the shutter policy: ordinary instability only warns; severe movement
    /// holds the shutter when the calibration says so.
    private var canCapture: Bool {
        guard !isCapturing, stability.allowsCapture else { return false }
        return isNative ? camera.isRunning : true
    }

    private var controls: some View {
        VStack(spacing: VE.Space.s) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
            controlRow
        }
        .padding(.top, VE.Space.s)
        .padding(.bottom, VE.Space.m)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VE.warning)
            Text(message)
                .font(VE.Font.caption)
                .foregroundStyle(VE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(state.t("camera.error.retry")) {
                errorMessage = nil
                camera.clearFailure()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(VE.copper)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, VE.Space.m)
        .padding(.vertical, 11)
        .background(VE.surface, in: .rect(cornerRadius: VE.Radius.tile))
        .padding(.horizontal, VE.Space.m)
        .accessibilityIdentifier("camera.error")
    }

    private var controlRow: some View {
        HStack {
            lastThumbnail
            Spacer()
            shutter
            Spacer()
            Button {} label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(VE.textSecondary)
                    .frame(width: 52, height: 52)
                    .background(VE.surface, in: .circle)
            }
            .disabled(isCapturing)
            .accessibilityLabel("Alternar câmara")
        }
        .padding(.horizontal, 28)
    }

    private var lastThumbnail: some View {
        Group {
            if let capture = state.captures.first {
                CaptureImage(capture: capture)
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VE.border, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(VE.surface)
                    .frame(width: 52, height: 52)
            }
        }
        .accessibilityHidden(true)
    }

    private var shutter: some View {
        Button {
            Task { await runCapture() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(VE.copper.opacity(0.35), lineWidth: 2)
                    .frame(width: 92, height: 92)
                    .scaleEffect(shutterPulse ? 1.08 : 1)
                Circle()
                    .fill(
                        LinearGradient(colors: [VE.copper, VE.copperDeep], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 74, height: 74)
                    .opacity(isCapturing ? 0.75 : 1)
                Circle()
                    .strokeBorder(VE.overlay.opacity(0.55), lineWidth: 3)
                    .frame(width: 62, height: 62)
                if isCapturing, let frame = activeFrame {
                    Text(CaptureProfile.evLabel(frame))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x1B1410))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCapture)
        .accessibilityIdentifier("camera.shutter")
        .accessibilityLabel(state.t("home.cta.capture"))
    }

    // MARK: - Capture

    /// READY → CAPTURING → LOCAL_VALIDATING → LOCAL_READY.
    ///
    /// One tap owns one capture attempt in both modes. The shutter, the room chips and the lens
    /// control stay locked for its duration, and the attempt id — never a time window — is what
    /// makes the resulting registration idempotent.
    private func runCapture() async {
        guard canCapture, !previewCapturing else { return }
        if isNative { await runNativeCapture() } else { await runSimulatedSequence() }
    }

    /// Native capture: one tap photographs the whole exposure ladder this device supports,
    /// persists every frame, validates the bundle and only then shows the approved confirmation.
    /// The person holding the phone sees the same subtle feedback as always — never a technical
    /// progress read-out of individual exposures.
    private func runNativeCapture() async {
        guard camera.access.isAuthorized else {
            errorMessage = state.t("camera.permission.body")
            return
        }
        let tapAt = Date()
        guard let attempt = state.beginCaptureAttempt(property: property, room: room) else { return }

        isCapturing = true
        errorMessage = nil
        // Roll, pitch and the "before" stability are frozen at the tap.
        stability.beginCaptureWindow()
        let feedback = Task { await sweepLadder() }
        defer { feedback.cancel() }

        let result: BracketCaptureResult
        do {
            result = try await camera.captureBracket(
                clientCaptureID: attempt.id,
                tapAt: tapAt,
                availableBytesOverride: state.devAvailableBytesOverride
            )
        } catch {
            let context = recordingContext(motion: stability.endCaptureWindow())
            guard let failure = error as? BracketCaptureFailure else {
                report((error as? CameraError) ?? .bracketCaptureFailed, attempt: attempt, manifest: nil, result: nil)
                return
            }
            // Whatever reached the device is kept as an incomplete attempt — never as a capture.
            let manifest = CaptureManifestBuilder.recordFailure(
                failure,
                attempt: attempt,
                property: property,
                organizationID: state.organizationName,
                context: context
            )
            report(failure.code, attempt: attempt, manifest: manifest, result: failure.partial)
            return
        }

        let context = recordingContext(motion: stability.endCaptureWindow())
        let finalizeStartedAt = Date()
        do {
            state.beginLocalValidation()
            let manifest = try CaptureManifestBuilder.finalize(
                result: result,
                attempt: attempt,
                property: property,
                organizationID: state.organizationName,
                context: context
            )
            state.cameraDiagnostics.lastCaptureSeconds = result.bracketSeconds
            state.cameraDiagnostics.lastManifest = manifest
            state.cameraDiagnostics.lastErrorCode = nil
            syncDiagnostics()
            recordRun(
                attempt: attempt,
                manifest: manifest,
                failure: nil,
                result: result,
                finalizeMs: Date().timeIntervalSince(finalizeStartedAt) * 1000
            )
            finishCapturing()
            onCaptured(
                attempt,
                CaptureOutcome(
                    frameCount: manifest.actualFrameCount,
                    localFile: manifest.referenceFrame?.localPhotoFile,
                    manifest: manifest
                )
            )
        } catch {
            let code = (error as? CameraError) ?? .bracketCaptureFailed
            report(code, attempt: attempt, manifest: CaptureBundleStore.readManifest(clientCaptureID: attempt.id), result: result)
        }
    }

    private func recordingContext(motion: CaptureMotionSnapshot) -> CaptureRecordingContext {
        CaptureRecordingContext(motion: motion, capturedOffline: !state.isOnline, qaTag: state.qaTag)
    }

    private func report(_ code: CameraError, attempt: CaptureAttempt, manifest: CaptureManifest?, result: BracketCaptureResult?) {
        state.cameraDiagnostics.lastErrorCode = code.code
        state.cameraDiagnostics.lastManifest = manifest
        syncDiagnostics()
        recordRun(attempt: attempt, manifest: manifest, failure: code, result: result, finalizeMs: nil)
        errorMessage = state.t(code.localizationKey)
        finishCapturing()
    }

    private func recordRun(
        attempt: CaptureAttempt,
        manifest: CaptureManifest?,
        failure: CameraError?,
        result: BracketCaptureResult?,
        finalizeMs: Double?
    ) {
        let memory = DeviceHealthProbe.memoryFootprintMB()
        let thermal = DeviceHealthProbe.thermalStateLabel()
        state.recordCaptureRun(
            CaptureRunMetric(
                clientCaptureID: attempt.id,
                at: .now,
                succeeded: failure == nil,
                frameCount: manifest?.actualFrameCount ?? 0,
                bracketDurationMs: manifest?.quality?.bracketDurationMs,
                tapToCaptureStartMs: manifest?.quality?.tapToCaptureStartMs,
                memoryFootprintMB: memory,
                thermalState: thermal,
                qualityClass: manifest?.quality?.qualityClass,
                failureCode: failure?.code
            )
        )
        // Physical validation evidence — only while a session is open in the Camera Lab.
        state.recordValidationRun(
            ValidationRun(
                clientCaptureID: attempt.id,
                at: .now,
                launchID: PhysicalValidationStore.currentLaunchID,
                succeeded: failure == nil,
                failureCode: failure?.code,
                profile: manifest?.captureProfile.devLabel ?? result?.plan.profile.devLabel,
                lens: manifest?.lensType ?? result?.lensType,
                frameCount: manifest?.actualFrameCount ?? 0,
                totalBytes: manifest?.totalByteCount ?? 0,
                capturedOffline: !state.isOnline,
                tapToCaptureStartMs: result?.tapToCaptureStartMs,
                tapToFirstFrameMs: result?.tapToFirstFrameMs,
                bracketDurationMs: result?.bracketDurationMs,
                framePersistMs: result.map { $0.persistSeconds * 1000 },
                finalizeMs: finalizeMs,
                memoryFootprintMB: memory,
                thermalState: thermal,
                qualityClass: manifest?.quality?.qualityClass
            )
        )
    }

    /// Starts the real camera with the calibration-preferred lens (or the developer lens test)
    /// and hands the resolved calibration to the stability analysis.
    private func startCamera() async {
        camera.onSessionEvent = { [state] kind in state.recordCameraSessionEvent(kind) }
        await camera.start(lensOverride: state.devLensOverride)
        stability.apply(camera.calibration)
        syncDiagnostics()
    }

    private func syncDiagnostics() {
        state.cameraDiagnostics.mode = state.cameraMode
        state.cameraDiagnostics.access = camera.access
        state.cameraDiagnostics.setup = camera.setup
        state.cameraDiagnostics.capabilities = camera.capabilities
        state.cameraDiagnostics.plan = camera.plan
        state.cameraDiagnostics.calibration = camera.calibration
    }

    /// The approved simulation: one tap runs the whole nine-exposure sequence.
    private func runSimulatedSequence() async {
        guard let attempt = state.beginCaptureAttempt(property: property, room: room) else { return }

        isCapturing = true
        await animateBracket()
        finishCapturing()
        onCaptured(attempt, CaptureOutcome(frameCount: simulatedExposures.count))
    }

    /// Subtle capture feedback while the real bracket runs: the same hairline ladder animation
    /// the approved design already uses, never a per-exposure progress screen.
    private func sweepLadder() async {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { shutterPulse = true }
        while !Task.isCancelled {
            for value in exposures where !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.1)) { activeFrame = value }
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func finishCapturing() {
        withAnimation(.easeOut(duration: 0.2)) { activeFrame = nil }
        isCapturing = false
        shutterPulse = false
        state.endCaptureSequence()
    }

    private func animateBracket() async {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { shutterPulse = true }
        if previewCapturing { isCapturing = true }

        for value in exposures {
            withAnimation(.easeOut(duration: 0.1)) { activeFrame = value }
            try? await Task.sleep(for: .milliseconds(130))
        }

        withAnimation(.easeOut(duration: 0.2)) { activeFrame = nil }
        shutterPulse = false
    }
}
