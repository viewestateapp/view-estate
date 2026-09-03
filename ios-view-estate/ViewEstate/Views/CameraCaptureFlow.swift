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
                onCaptured: { frameCount in
                    let capture = state.registerCapture(property: property, room: room, frameCount: frameCount)
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

/// Visual prototype of the professional capture tool. No camera hardware is accessed:
/// the exposure sequence, stability read-out and shutter are a faithful UI simulation.
struct CameraPrototypeView: View {
    let property: Property
    @Binding var room: RoomType
    var previewCapturing: Bool = false
    let onCaptured: (Int) -> Void
    let onClose: () -> Void

    @Environment(AppState.self) private var state

    @State private var isCapturing = false
    @State private var activeFrame: Int?
    @State private var isStable = true
    @State private var levelOffset: CGFloat = 0
    @State private var shutterPulse = false

    private let exposures: [Int] = [-4, -3, -2, -1, 0, 1, 2, 3, 4]

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            viewfinder
            roomChips
            controls
        }
        .background(VE.overlay.ignoresSafeArea())
        .task { await driftLevel() }
        .task {
            guard previewCapturing else { return }
            while !Task.isCancelled {
                await animateBracket()
            }
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
                tint: isCapturing ? VE.copper : VE.success,
                filled: true
            )
            if !state.isOnline {
                statusChip(text: state.t("camera.offline"), tint: VE.warning, filled: false)
            } else {
                statusChip(
                    text: isStable ? state.t("camera.stable") : state.t("camera.stabilizing"),
                    tint: isStable ? VE.textSecondary : VE.warning,
                    filled: false
                )
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
                    .overlay {
                        Image(room.placeholderImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(frameBrightness)
                            .allowsHitTesting(false)
                    }
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

    /// Advanced, ignorable technical information: a hairline exposure ladder.
    private var exposureStrip: some View {
        HStack(spacing: 0) {
            ForEach(exposures, id: \.self) { value in
                let active = activeFrame == value
                VStack(spacing: 3) {
                    Text(value > 0 ? "+\(value)" : "\(value)")
                        .font(VE.Font.mono)
                        .foregroundStyle(active ? VE.copper : (value == 0 ? VE.textSecondary : VE.textTertiary))
                    Rectangle()
                        .fill(active ? VE.copper : VE.textTertiary.opacity(0.4))
                        .frame(width: 1, height: value == 0 ? 8 : 5)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.12), value: activeFrame)
            }

            Text("HDR · \(exposures.count)")
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

    private func levelIndicator(width: CGFloat) -> some View {
        Rectangle()
            .fill(isStable ? VE.textPrimary.opacity(0.9) : VE.warning)
            .frame(width: width * 0.55, height: 1.5)
            .rotationEffect(.degrees(levelOffset))
            .animation(.easeInOut(duration: 0.8), value: levelOffset)
            .allowsHitTesting(false)
    }

    private var frameBrightness: Double {
        guard let frame = activeFrame else { return 0.62 }
        return min(1.0, max(0.12, 0.62 + Double(frame) * 0.11))
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

    private var controls: some View {
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
        .padding(.top, VE.Space.s)
        .padding(.bottom, VE.Space.m)
    }

    private var lastThumbnail: some View {
        Group {
            if let capture = state.captures.first {
                Image(capture.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
            Task { await runSequence() }
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
                    Text(frame > 0 ? "+\(frame)" : "\(frame)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x1B1410))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel(state.t("home.cta.capture"))
    }

    // MARK: - Simulated bracket

    /// One tap runs the whole nine-exposure sequence. The shutter is locked for its
    /// duration, so repeated taps can never produce duplicate captures.
    private func runSequence() async {
        guard !isCapturing, !previewCapturing else { return }
        guard state.beginCaptureSequence() else { return }

        isCapturing = true
        await animateBracket()
        isCapturing = false
        state.endCaptureSequence()
        onCaptured(exposures.count)
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

    private func driftLevel() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1600))
            let drift = Double.random(in: -1.2...1.2)
            levelOffset = drift
            isStable = abs(drift) < 0.8
        }
    }
}
