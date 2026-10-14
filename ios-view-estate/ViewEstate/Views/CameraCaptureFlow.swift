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
/// An immersive, photography-first viewfinder: a full-width 4:3 live preview carrying only quiet
/// photographic guides, a hairline top bar with the property and room, and every control gathered
/// below the image around one dominant shutter. With `camera_native_enabled` OFF the viewfinder is
/// a faithful UI simulation; with it ON the real rear camera runs behind exactly the same interface
/// and one shutter tap photographs a real multi-exposure bracket. The exposure sequence is never
/// surfaced — no EV ladder, no frame counter.
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
    /// Real device motion: drives the stability indicator, the level guide and the shutter policy.
    @State private var stability = CameraStabilityService()
    @State private var isCapturing = false
    @State private var activeFrame: Double?
    @State private var shutterPulse = false
    @State private var errorMessage: String?
    @State private var showRoomPicker = false
    @State private var showGallery = false
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

    /// The session itself is unavailable — the only time a camera-open error may appear.
    private var isOpenFailure: Bool {
        guard isNative, !camera.isRunning, let failure = camera.failure else { return false }
        return failure != .permissionDenied
    }

    var body: some View {
        GeometryReader { geometry in
            let controlsMinHeight: CGFloat = 178
            let fullHeight = geometry.size.width * 4 / 3
            let previewHeight = max(0, min(fullHeight, geometry.size.height - controlsMinHeight))
            let previewWidth = previewHeight < fullHeight ? previewHeight * 3 / 4 : geometry.size.width

            VStack(spacing: 0) {
                viewfinder
                    .frame(width: previewWidth, height: previewHeight)
                    .frame(maxWidth: .infinity)
                bottomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VE.overlay.ignoresSafeArea())
        .statusBarHidden(false)
        .sensoryFeedback(.impact(weight: .medium), trigger: isCapturing) { _, capturing in capturing }
        .sensoryFeedback(.selection, trigger: room)
        .sheet(isPresented: $showRoomPicker) { roomPickerSheet }
        .sheet(isPresented: $showGallery) {
            GalleryView()
                .preferredColorScheme(.dark)
        }
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VE.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.35), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.t("common.close"))

            Button {
                showRoomPicker = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(property.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VE.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(state.roomName(room))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VE.copper)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(VE.copper.opacity(0.8))
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)
            .accessibilityLabel("\(property.title), \(state.roomName(room))")
            .accessibilityHint(state.t("camera.tool.room"))

            Spacer(minLength: 8)

            statusIndicator
        }
        .padding(.leading, 6)
        .padding(.trailing, VE.Space.m)
        .padding(.top, 2)
    }

    /// A dot and a word — never a pill.
    @ViewBuilder
    private var statusIndicator: some View {
        let status: (text: String, tint: Color)? = {
            if isCapturing { return (state.t("camera.capturing"), VE.copper) }
            if !state.isOnline { return (state.t("camera.offline"), VE.warning) }
            guard isCameraLive else { return nil }
            return (state.t(stabilityState.localizationKey), isStable ? VE.success : VE.warning)
        }()
        if let status {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.tint)
                    .frame(width: 6, height: 6)
                Text(status.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VE.textPrimary.opacity(0.88))
            }
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: status.text)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        Color.black
            .overlay { viewfinderContent }
            .overlay {
                if showsGrid, !isOpenFailure { CompositionGrid().allowsHitTesting(false) }
            }
            .overlay {
                if showsLevel, !isOpenFailure, isCameraLive { levelGuide }
            }
            .overlay {
                // A whisper of dimming while the sequence runs — the exposures stay invisible.
                Color.black
                    .opacity(isCapturing ? 0.14 : 0)
                    .animation(.easeOut(duration: 0.18), value: isCapturing)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
                    .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { previewFooter }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(state.t("camera.prototype"))
    }

    /// The live rear camera in native mode, the reference frame in simulated mode, and a
    /// friendly explanation when iOS is holding camera access back.
    @ViewBuilder
    private var viewfinderContent: some View {
        if isNative, camera.access.needsSystemSettings {
            permissionState
        } else if isOpenFailure {
            openFailureState
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

    /// Transient capture message and the lens indicator, resting on the bottom of the image.
    private var previewFooter: some View {
        VStack(spacing: 10) {
            if let errorMessage, !isOpenFailure {
                captureMessage(errorMessage)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !isOpenFailure, !(isNative && camera.access.needsSystemSettings) {
                lensIndicator
            }
        }
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.22), value: errorMessage)
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

    /// Shows the physical lens in use. A second option appears only once a device's ultra-wide
    /// has been approved through calibration — it is never offered by default.
    private var lensIndicator: some View {
        let label = camera.activeLens == .ultraWide && isNative ? "0.5" : "1×"
        return Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(VE.copper)
            .frame(width: 34, height: 34)
            .background(.black.opacity(0.42), in: .circle)
            .overlay(Circle().strokeBorder(VE.copper.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel("\(state.t("camera.lens")) \(label)")
    }

    /// Camera-style alignment: fixed reference ticks, a horizon line that counter-rotates
    /// against the phone's real roll, and a small centre marker. Green when level, amber when
    /// not. No degrees are ever shown. The source image is never rotated.
    private var levelGuide: some View {
        let tint: Color = isLevel ? VE.success : VE.warning
        return GeometryReader { geometry in
            let w = geometry.size.width
            ZStack {
                HStack(spacing: 0) {
                    Rectangle().frame(width: 20, height: 1)
                    Spacer().frame(width: w * 0.34)
                    Rectangle().frame(width: 20, height: 1)
                }
                .foregroundStyle(isLevel ? tint.opacity(0.9) : VE.textPrimary.opacity(0.55))

                Rectangle()
                    .fill(tint.opacity(isLevel ? 0.9 : 0.95))
                    .frame(width: w * 0.3, height: 1.2)
                    .rotationEffect(.degrees(-levelAngle))

                Circle()
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1)
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

    /// Interior / Exterior as a camera mode dial. Switching mode moves to the first room of that
    /// kind; detailed room switching stays in the top bar and the room button.
    private var modeSelector: some View {
        let interior = availableRooms.first { !$0.isExteriorScene }
        let exterior = availableRooms.first { $0.isExteriorScene }
        return HStack(spacing: 26) {
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
        .disabled(isCapturing)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExteriorMode)
    }

    private func modeLabel(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(active ? VE.copper : VE.textPrimary.opacity(0.5))
                Circle()
                    .fill(VE.copper)
                    .frame(width: 4, height: 4)
                    .opacity(active ? 1 : 0)
            }
            .frame(minHeight: 32)
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
            Spacer(minLength: 8)
            modeSelector
            Spacer(minLength: 10)
            shutterRow
            Spacer(minLength: 10)
            utilityRow
            Spacer(minLength: 4)
        }
    }

    private var shutterRow: some View {
        HStack {
            galleryThumbnail
            Spacer()
            shutter
            Spacer()
            roomButton
        }
        .padding(.horizontal, 34)
    }

    private var galleryThumbnail: some View {
        Button {
            showGallery = true
        } label: {
            Group {
                if let capture = state.captures.first {
                    CaptureImage(capture: capture)
                        .frame(width: 46, height: 46)
                        .clipShape(.rect(cornerRadius: 9))
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(VE.surface)
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(VE.textTertiary)
                        }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(VE.textPrimary.opacity(0.22), lineWidth: 1))
            .frame(width: 52, height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(ShutterPressStyle(scale: 0.92))
        .disabled(isCapturing)
        .accessibilityLabel(state.t("camera.tool.gallery"))
    }

    /// The secondary action: the current room's symbol, opening the room chooser.
    private var roomButton: some View {
        Button {
            showRoomPicker = true
        } label: {
            Image(systemName: room.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(VE.textPrimary.opacity(0.9))
                .frame(width: 48, height: 48)
                .background(VE.textPrimary.opacity(0.1), in: .circle)
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(ShutterPressStyle(scale: 0.9))
        .disabled(isCapturing)
        .accessibilityLabel(state.t("camera.tool.room"))
    }

    private var utilityRow: some View {
        HStack(spacing: 36) {
            utilityToggle(systemImage: "squareshape.split.3x3", title: state.t("camera.tool.grid"), isOn: $showsGrid)
            utilityToggle(systemImage: "level", title: state.t("camera.tool.level"), isOn: $showsLevel)
        }
    }

    private func utilityToggle(systemImage: String, title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOn.wrappedValue.toggle() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? VE.copper : VE.textPrimary.opacity(0.45))
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
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
                    .strokeBorder(VE.copper.opacity(isCapturing ? 0 : 0.45), lineWidth: 1)
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
