import SwiftUI

/// Capture experience presented full screen.
///
/// The photographer stays in the camera: a successful shutter shows a brief, non-blocking
/// "Capturada", updates the thumbnail at once and hands the photo to background preparation.
/// The thumbnail opens the photo viewer straight away — EV 0 while preparing, the HDR master
/// once ready. Leaving a room is the photographer's decision ("Concluir divisão"), which opens
/// the room review. The full "Captura concluída" screen is kept only as a development fallback.
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
    @State private var showRoomReview = false
    @State private var viewerCaptureID: UUID?

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
                    UIAccessibility.post(notification: .announcement, argument: state.t("camera.feedback.captured"))
                    if state.captureSummaryScreenEnabled {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            completedCapture = capture
                        }
                    }
                },
                onOpenPhoto: { id in
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { viewerCaptureID = id }
                },
                onFinishRoom: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { showRoomReview = true }
                },
                onClose: { dismiss() }
            )

            if showRoomReview {
                RoomReviewView(
                    property: property,
                    room: room,
                    onOpen: { id in
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { viewerCaptureID = id }
                    },
                    onContinue: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { showRoomReview = false }
                    },
                    onNextRoom: { showRoomPicker = true },
                    onFinish: { dismiss() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

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
                .zIndex(2)
            }

            if let viewerCaptureID {
                // The same viewer every gallery opens; shown in place so the live camera keeps
                // running underneath and closing returns to it instantly.
                PhotoViewer(
                    captureID: viewerCaptureID,
                    onClose: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) { self.viewerCaptureID = nil }
                    },
                    onRecapture: { _, recaptureRoom in
                        room = recaptureRoom
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                            showRoomReview = false
                            completedCapture = nil
                        }
                    }
                )
                .id(viewerCaptureID)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(3)
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
                    withAnimation(.easeInOut(duration: 0.25)) {
                        completedCapture = nil
                        showRoomReview = false
                    }
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
        .statusBarHidden(viewerCaptureID != nil)
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
/// An immersive, photography-first viewfinder: the image dominates nearly the whole screen,
/// carrying only quiet photographic guides, a near-invisible header with the property and room,
/// and every control gathered below the image around one dominant shutter. With `camera_native_enabled` OFF the viewfinder is
/// a faithful UI simulation; with it ON the real rear camera runs behind exactly the same interface
/// and one shutter tap photographs a real multi-exposure bracket. The exposure sequence is never
/// surfaced — no EV ladder, no frame counter.
struct CameraPrototypeView: View {
    let property: Property
    @Binding var room: RoomType
    var previewCapturing: Bool = false
    /// Delivers the finished capture together with the attempt that produced it.
    let onCaptured: (CaptureAttempt, CaptureOutcome) -> Void
    /// Opens the photo viewer for a capture (the bottom-left thumbnail).
    var onOpenPhoto: (UUID) -> Void = { _ in }
    /// The photographer decided this room is done.
    var onFinishRoom: () -> Void = {}
    let onClose: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = CameraService()
    /// Real device motion: drives the stability indicator, the level guide and the shutter policy.
    @State private var stability = CameraStabilityService()
    @State private var isCapturing = false
    @State private var activeFrame: Double?
    @State private var shutterPulse = false
    @State private var errorMessage: String?
    @State private var showRoomPicker = false
    /// Orientation the overlay is currently laid out in; follows the phone with a short cross-fade.
    @State private var overlayOrientation: CaptureOrientation = .portrait
    @State private var overlayOpacity: Double = 1
    /// Brief "✓ Capturada" after a successful shutter. Never blocks the camera.
    @State private var capturedFeedback: UUID?
    @AppStorage("ve.camera.grid") private var showsGrid: Bool = true
    @AppStorage("ve.camera.level") private var showsLevel: Bool = true

    /// The prototype always runs the full ladder internally; profiles are a real-camera concern.
    private let simulatedExposures: [Double] = CaptureProfile.full9.exposureValues

    /// In native mode the ladder is whatever this device can genuinely photograph.
    private var exposures: [Double] {
        isNative ? camera.plan.exposureValues : simulatedExposures
    }

    private var stabilityState: StabilityState { stability.displayState }
    private var isStable: Bool { stabilityState == .stable }

    /// Horizon tilt shown by the level guide, kept subtle.
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

    /// Physical orientation the camera interface follows. The iPhone shell is portrait-only, so
    /// the camera counter-rotates its own overlay and glyphs; an iPad rotates its whole interface
    /// and needs no counter-rotation.
    private var uiOrientation: CaptureOrientation {
        UIDevice.current.userInterfaceIdiom == .phone ? stability.orientation : .portrait
    }

    private var glyphRotation: Angle { uiOrientation.interfaceRotation }

    /// Most recent photograph of this property — the thumbnail, updated the moment a capture
    /// registers.
    private var latestCapture: CaptureItem? {
        state.captures.first { $0.propertyID == property.id }
    }

    private var roomHasPhotos: Bool {
        state.captures.contains { $0.propertyID == property.id && $0.room == room }
    }

    /// The session itself is unavailable — the only time a camera-open error may appear.
    private var isOpenFailure: Bool {
        guard isNative, !camera.isRunning, let failure = camera.failure else { return false }
        return failure != .permissionDenied
    }

    var body: some View {
        GeometryReader { geometry in
            // The image is always full width; on tall phones it takes the full 4:3 height.
            let controlsMinHeight: CGFloat = 208
            let fullHeight = geometry.size.width * 4 / 3
            let previewHeight = max(0, min(fullHeight, geometry.size.height - controlsMinHeight))

            VStack(spacing: 0) {
                viewfinder
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                bottomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VE.overlay.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .medium), trigger: isCapturing) { _, capturing in capturing }
        .sensoryFeedback(.selection, trigger: room)
        .sensoryFeedback(.success, trigger: capturedFeedback) { _, new in new != nil }
        .sheet(isPresented: $showRoomPicker) { roomPickerSheet }
        .onAppear {
            stability.start()
            overlayOrientation = uiOrientation
        }
        .onChange(of: uiOrientation) { _, next in
            rotateOverlay(to: next)
        }
        .task(id: capturedFeedback) {
            guard capturedFeedback != nil else { return }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { capturedFeedback = nil }
        }
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
                state.cameraDiagnostics.lastErrorCode = failure.code
            }
        }
        .task(id: errorMessage) {
            // Capture messages are transient: they fade on their own.
            guard errorMessage != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { errorMessage = nil }
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

    // MARK: - Header

    /// Almost nothing: property and room centred, tiny, and a word of status only when useful.
    /// Readiness is the absence of an error, so a stable camera shows no status at all.
    private var headerOverlay: some View {
        VStack(spacing: 5) {
            Button {
                showRoomPicker = true
            } label: {
                VStack(spacing: 1) {
                    Text(property.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VE.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(state.roomName(room))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(VE.copper)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(VE.copper.opacity(0.8))
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)
            .accessibilityLabel("\(property.title), \(state.roomName(room))")
            .accessibilityHint(state.t("camera.tool.room"))

            statusText
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var statusText: some View {
        let status: (text: String, tint: Color)? = {
            if isCapturing { return (state.t("camera.capturing"), VE.copper) }
            if !state.isOnline { return (state.t("camera.offline"), VE.warning) }
            guard isCameraLive, !isStable else { return nil }
            return (state.t(stabilityState.localizationKey), VE.warning)
        }()
        if let status {
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.tint)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: status.text)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Viewfinder

    /// The live image stays fixed to the hardware — held sideways, this 4:3 rectangle IS the
    /// landscape 4:3 photograph. Everything drawn over it (grid, level, header, mode, messages)
    /// is laid out in the phone's physical orientation, so it always reads upright.
    private var viewfinder: some View {
        Color.black
            .overlay { viewfinderContent }
            .overlay {
                // A whisper of dimming while the sequence runs — the exposures stay invisible.
                Color.black
                    .opacity(isCapturing ? 0.14 : 0)
                    .animation(.easeOut(duration: 0.18), value: isCapturing)
                    .allowsHitTesting(false)
            }
            .overlay {
                OrientedContainer(orientation: overlayOrientation) {
                    physicalOverlay
                }
                .opacity(overlayOpacity)
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(state.t("camera.prototype"))
    }

    /// Overlay in physical coordinates: top is the top of the photograph being taken.
    private var physicalOverlay: some View {
        ZStack {
            if showsGrid, !isOpenFailure { CompositionGrid().allowsHitTesting(false) }
            if showsLevel, !isOpenFailure, isCameraLive { levelGuide }

            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { headerOverlay }
        .overlay(alignment: .topTrailing) { queueIndicator }
        .overlay(alignment: .bottom) { previewFooter }
        .overlay(alignment: .bottom) { modeChip.padding(.bottom, 52) }
    }

    /// "3 a preparar": photographs (never exposures) still preparing in the background.
    @ViewBuilder
    private var queueIndicator: some View {
        let count = state.captures.filter { $0.propertyID == property.id && $0.status == .preparing }.count
        if count > 0, !isOpenFailure {
            HStack(spacing: 5) {
                PreparingDots(tint: VE.textPrimary.opacity(0.85))
                Text(state.t("camera.queue", count))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(VE.textPrimary.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4), in: .capsule)
            .padding(.top, 8)
            .padding(.trailing, 10)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: count)
            .accessibilityElement(children: .combine)
        }
    }

    /// Cross-fades the overlay into the new physical orientation. The camera session, the
    /// selected property and room, and any running attempt are untouched.
    private func rotateOverlay(to next: CaptureOrientation) {
        guard next != overlayOrientation else { return }
        Task {
            withAnimation(.easeIn(duration: 0.12)) { overlayOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(120))
            overlayOrientation = next
            withAnimation(.easeOut(duration: 0.2)) { overlayOpacity = 1 }
        }
    }

    /// The live rear camera in native mode, the reference frame in simulated mode, and a
    /// friendly explanation when iOS is holding camera access back.
    @ViewBuilder
    private var viewfinderContent: some View {
        if isNative, camera.access.needsSystemSettings {
            OrientedContainer(orientation: overlayOrientation) { permissionState }
        } else if isOpenFailure {
            OrientedContainer(orientation: overlayOrientation) { openFailureState }
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
                .opacity(0.9)
                .allowsHitTesting(false)
        }
    }

    private var permissionState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(VE.textTertiary)
            VStack(spacing: 6) {
                Text(state.t("camera.permission.title"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                Text(state.t("camera.permission.body"))
                    .font(.system(size: 13))
                    .foregroundStyle(VE.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                camera.openSystemSettings()
            } label: {
                Text(state.t("camera.permission.cta"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VE.copper)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera.openSettings")
        }
        .padding(.horizontal, VE.Space.xl)
    }

    /// Compact and inline — one line and one action, centred in the black frame.
    private var openFailureState: some View {
        VStack(spacing: 10) {
            Text(state.t("camera.open.failed"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VE.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    camera.clearFailure()
                    await startCamera()
                    if let failure = camera.failure, failure != .permissionDenied {
                        state.cameraDiagnostics.lastErrorCode = failure.code
                    }
                }
            } label: {
                Text(state.t("camera.open.retry"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VE.copper)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, VE.Space.xl)
        .accessibilityIdentifier("camera.error")
    }

    /// Transient capture message or the brief "✓ Capturada", kept above the mode chip.
    private var previewFooter: some View {
        VStack {
            if let errorMessage, !isOpenFailure {
                captureMessage(errorMessage)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if capturedFeedback != nil {
                capturedToast
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .padding(.bottom, 104)
        .animation(.easeOut(duration: 0.22), value: errorMessage)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: capturedFeedback)
    }

    private var capturedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(VE.success)
            Text(state.t("camera.feedback.captured"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VE.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: .capsule)
        .accessibilityHidden(true)
        .accessibilityIdentifier("camera.feedback.captured")
    }

    private func captureMessage(_ message: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { errorMessage = nil }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(VE.warning)
                    .frame(width: 6, height: 6)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VE.textPrimary.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: VE.Radius.chip))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, VE.Space.l)
        .accessibilityIdentifier("camera.error")
    }

    /// Camera-style alignment cross: a fixed vertical reference, a horizontal horizon that
    /// counter-rotates against the phone's real roll, and a centre marker. Ready green when
    /// level, warning amber when not. No degrees are ever shown. The image is never rotated.
    private var levelGuide: some View {
        let tint: Color = isLevel ? VE.success : VE.warning
        return GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                Rectangle()
                    .fill(tint.opacity(0.8))
                    .frame(width: 1, height: h * 0.26)

                Rectangle()
                    .fill(tint)
                    .frame(width: w * 0.34, height: 1.2)
                    .rotationEffect(.degrees(-levelAngle))

                Circle()
                    .strokeBorder(tint.opacity(0.9), lineWidth: 1)
                    .frame(width: 9, height: 9)
                    .background(Circle().fill(.black.opacity(0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.35), radius: 2)
        }
        .animation(.easeOut(duration: 0.12), value: levelAngle)
        .animation(.easeOut(duration: 0.2), value: isLevel)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Rooms & mode

    private var availableRooms: [RoomType] {
        property.rooms.isEmpty ? RoomPresets.fallback : property.rooms
    }

    private var isExteriorMode: Bool { room.isExteriorScene }

    /// A small floating mode control over the lower edge of the image. Switching mode moves to
    /// the first room of that kind; detailed room switching stays in the header and room button.
    private var modeChip: some View {
        let interior = availableRooms.first { !$0.isExteriorScene }
        let exterior = availableRooms.first { $0.isExteriorScene }
        return HStack(spacing: 18) {
            if let interior {
                modeLabel(state.t("camera.mode.interior"), active: !isExteriorMode) {
                    guard isExteriorMode else { return }
                    room = interior
                }
            }
            if let exterior {
                modeLabel(state.t("camera.mode.exterior"), active: isExteriorMode) {
                    guard !isExteriorMode else { return }
                    room = exterior
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: .capsule)
        .disabled(isCapturing)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExteriorMode)
        .accessibilityElement(children: .contain)
    }

    private func modeLabel(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(active ? VE.copper : VE.textPrimary.opacity(0.55))
                .frame(minHeight: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var roomPickerSheet: some View {
        NavigationStack {
            RoomPickerContent(property: property, suggested: nil, currentRoom: room) { picked in
                room = picked
                showRoomPicker = false
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
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
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

    private var bottomControls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 6)
            zoomRow
            Spacer(minLength: 6)
            shutterRow
            Spacer(minLength: 12)
            controlToolbar
            Spacer(minLength: 2)
        }
    }

    /// Zoom sits just below the image, like the reference. 0.5× appears only while the Camera
    /// Lab forces the ultra-wide — an uncalibrated lens is never exposed in production.
    private var zoomRow: some View {
        let ultraWideActive = isNative && camera.activeLens == .ultraWide
        return HStack(spacing: 56) {
            if ultraWideActive {
                Text("0.5×")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VE.copper)
            }
            Text("1×")
                .font(.system(size: 15, weight: ultraWideActive ? .regular : .semibold))
                .foregroundStyle(ultraWideActive ? VE.textSecondary : VE.textPrimary)
        }
        .rotationEffect(glyphRotation)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: glyphRotation)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.t("camera.lens")) \(ultraWideActive ? "0.5" : "1")")
    }

    /// Close on the left; the two tools that actually work on the right. Nothing fake.
    private var controlToolbar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                    .rotationEffect(glyphRotation)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(VE.textPrimary.opacity(0.35), lineWidth: 1)
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.t("common.close"))

            Spacer()

            if roomHasPhotos {
                finishRoomButton
                    .transition(.opacity)
            }

            Spacer()

            toolbarToggle(systemImage: "square.grid.3x3", title: state.t("camera.tool.grid"), isOn: $showsGrid)
            toolbarToggle(systemImage: "level", title: state.t("camera.tool.level"), isOn: $showsLevel)
        }
        .padding(.horizontal, 24)
        .animation(.easeOut(duration: 0.2), value: roomHasPhotos)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: glyphRotation)
    }

    /// "Concluir divisão": the photographer, not the app, decides when a room is done. Held
    /// sideways the label would not fit the toolbar, so it becomes its glyph.
    private var finishRoomButton: some View {
        Button {
            onFinishRoom()
        } label: {
            Group {
                if uiOrientation.isLandscape {
                    Image(systemName: "checkmark.rectangle.stack")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(VE.copper)
                        .rotationEffect(glyphRotation)
                        .frame(width: 44, height: 40)
                } else {
                    Text(state.t("camera.room.finish"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VE.copper)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(VE.copper.opacity(0.45), lineWidth: 1))
                        .frame(minHeight: 44)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel(state.t("camera.room.finish"))
        .accessibilityIdentifier("camera.finishRoom")
    }

    private func toolbarToggle(systemImage: String, title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOn.wrappedValue.toggle() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? VE.copper : VE.textPrimary.opacity(0.55))
                .rotationEffect(glyphRotation)
                .frame(width: 44, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var shutterRow: some View {
        HStack {
            galleryThumbnail
            Spacer()
            shutter
            Spacer()
            roomButton
        }
        .padding(.horizontal, 32)
    }

    /// The last photograph, updated the moment it registers. Opens the photo viewer by capture
    /// id — in any preparation state.
    private var galleryThumbnail: some View {
        Button {
            guard let capture = latestCapture else { return }
            onOpenPhoto(capture.id)
        } label: {
            Group {
                if let capture = latestCapture {
                    Color(VE.elevated)
                        .frame(width: 44, height: 44)
                        .overlay {
                            CaptureImage(capture: capture)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.circle)
                        .rotationEffect(glyphRotation)
                        .id(capture.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Circle()
                        .fill(VE.textPrimary.opacity(0.12))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(VE.textTertiary)
                        }
                }
            }
            .overlay(Circle().strokeBorder(VE.textPrimary.opacity(0.22), lineWidth: 1))
            .frame(width: 50, height: 50)
            .contentShape(.circle)
            .animation(.spring(response: 0.38, dampingFraction: 0.75), value: latestCapture?.id)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: glyphRotation)
        }
        .buttonStyle(ShutterPressStyle(scale: 0.92))
        .disabled(isCapturing || latestCapture == nil)
        .accessibilityLabel(state.t("camera.tool.lastPhoto"))
        .accessibilityIdentifier("camera.thumbnail")
    }

    /// The secondary action: the current room's symbol, opening the room chooser.
    private var roomButton: some View {
        Button {
            showRoomPicker = true
        } label: {
            Image(systemName: room.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VE.textPrimary.opacity(0.9))
                .rotationEffect(glyphRotation)
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: glyphRotation)
                .frame(width: 44, height: 44)
                .background(VE.textPrimary.opacity(0.1), in: .circle)
                .frame(width: 50, height: 50)
                .contentShape(.circle)
        }
        .buttonStyle(ShutterPressStyle(scale: 0.9))
        .disabled(isCapturing)
        .accessibilityLabel(state.t("camera.tool.room"))
    }

    /// White, tactile, unmistakably the most important control. While the sequence runs, a
    /// copper arc travels the ring — the only capture feedback the person sees.
    private var shutter: some View {
        Button {
            Task { await runCapture() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(VE.textPrimary.opacity(0.92), lineWidth: 3.5)
                    .frame(width: 80, height: 80)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white, VE.textPrimary.opacity(0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: isCapturing ? 56 : 66, height: isCapturing ? 56 : 66)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Circle()
                    .strokeBorder(VE.copper.opacity(isCapturing ? 0 : 0.3), lineWidth: 1)
                    .frame(width: 70, height: 70)
                if isCapturing {
                    TimelineView(.animation) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                        Circle()
                            .trim(from: 0, to: 0.26)
                            .stroke(VE.copper, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .frame(width: 76.5, height: 76.5)
                            .rotationEffect(.degrees(angle))
                    }
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(.circle)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCapturing)
        }
        .buttonStyle(ShutterPressStyle(scale: 0.93))
        .opacity(canCapture || isCapturing ? 1 : 0.45)
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
        // Orientation is frozen at the tap: every exposure of this attempt uses it, and the
        // interface does not rotate until the bracket is finished.
        stability.freezeOrientation()
        let captureOrientation = stability.captureOrientation
        // Roll, pitch and the "before" stability are frozen at the tap.
        stability.beginCaptureWindow()
        let feedback = Task { await sweepLadder() }
        defer { feedback.cancel() }

        let result: BracketCaptureResult
        do {
            result = try await camera.captureBracket(
                clientCaptureID: attempt.id,
                tapAt: tapAt,
                availableBytesOverride: state.devAvailableBytesOverride,
                orientation: captureOrientation
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
            capturedFeedback = attempt.id
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
        stability.freezeOrientation()
        await animateBracket()
        finishCapturing()
        onCaptured(attempt, CaptureOutcome(frameCount: simulatedExposures.count))
        capturedFeedback = attempt.id
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
        stability.releaseOrientation()
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

/// Rule-of-thirds hairlines: present, photographic, never loud.
private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: w * fraction, y: 0))
                    path.addLine(to: CGPoint(x: w * fraction, y: h))
                    path.move(to: CGPoint(x: 0, y: h * fraction))
                    path.addLine(to: CGPoint(x: w, y: h * fraction))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// Tactile press for camera controls.
private struct ShutterPressStyle: ButtonStyle {
    var scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private extension RoomType {
    /// Rooms photographed as outdoor scenes; the camera's mode dial groups them as Exterior.
    var isExteriorScene: Bool {
        self == .exterior || self == .balcony
    }
}
