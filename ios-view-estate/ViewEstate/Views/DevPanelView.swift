import SwiftUI

/// Screens that can be opened directly for validation (`/dev/screens`).
enum DevScreen: String, Identifiable, CaseIterable {
    case cameraReady
    case cameraCapturing
    case captureCompleted
    case galleryPreparing
    case galleryReady
    case galleryNeedsRecapture
    case galleryError
    case offlineCapture

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cameraReady: "Camera — Ready"
        case .cameraCapturing: "Camera — Capturing"
        case .captureCompleted: "Capture Completed"
        case .galleryPreparing: "Gallery — Preparing"
        case .galleryReady: "Gallery — Ready"
        case .galleryNeedsRecapture: "Gallery — Needs Recapture"
        case .galleryError: "Gallery — Error"
        case .offlineCapture: "Offline Capture"
        }
    }

    var jobState: ProcessingJobState? {
        switch self {
        case .galleryPreparing: .processing
        case .galleryReady: .ready
        case .galleryNeedsRecapture: .needsReview
        case .galleryError: .failed
        default: nil
        }
    }
}

/// Development-only panel used to validate every UI state before real services exist.
/// Never reachable in a production build (guarded by `FeatureFlags.developerPanelEnabled`).
struct DevPanelView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var screen: DevScreen?

    private let creditPresets: [Int] = [0, 10, 25, 50, 100, 200]
    private let delayPresets: [Double] = [2, 4, 8, 20]

    var body: some View {
        NavigationStack {
            List {
                Section("Region") {
                    Picker("Region", selection: regionBinding) {
                        ForEach(Regions.all) { config in
                            Text("\(config.flag) \(config.countryName)").tag(config.code)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(VE.surface)

                Section("Capture result") {
                    Picker("Result", selection: resultBinding) {
                        ForEach(CaptureResultMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Picker("Preparation", selection: delayBinding) {
                        ForEach(delayPresets, id: \.self) { value in
                            Text("\(Int(value))s").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(VE.surface)

                Section("Screens") {
                    ForEach(DevScreen.allCases) { item in
                        Button(item.label) { open(item) }
                    }
                }
                .listRowBackground(VE.surface)
                .foregroundStyle(VE.textPrimary)

                Section("Camera") {
                    Picker("Camera Mode", selection: cameraModeBinding) {
                        ForEach(CameraMode.allCases) { mode in
                            Text(mode.devLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    flag("camera_native_enabled", state.cameraMode.isNative)
                    debugRow("Native Camera", state.cameraMode.isNative ? "ON" : "OFF")
                    debugRow("Permission", diagnostics.access.devLabel)
                    debugRow("captureSource", diagnostics.captureSource.devLabel)
                    debugRow("hdrSource", diagnostics.hdrSource.devLabel)
                    if let setup = diagnostics.setup {
                        debugRow("Device", setup.deviceName)
                        debugRow("iOS", setup.systemVersion)
                        debugRow("Camera ID", setup.deviceID)
                        debugRow("Lens", setup.lens)
                        debugRow("Capture resolution", setup.captureResolution)
                    } else {
                        Text("Native session not started in this run.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                    if let code = diagnostics.lastErrorCode {
                        debugRow("Last error", code)
                    }
                }
                .listRowBackground(VE.surface)

                Section("Exposure capability") {
                    if let capabilities = diagnostics.capabilities {
                        debugRow("min EV", capabilities.minExposureBiasDescription)
                        debugRow("max EV", capabilities.maxExposureBiasDescription)
                        debugRow("max bracket count", "\(capabilities.maxBracketCount)")
                        debugRow("Bracket capture", capabilities.supportsBracketCapture ? "YES" : "NO")
                        debugRow("Exposure lock", capabilities.supportsExposureLock ? "YES" : "NO")
                        debugRow("Custom exposure", capabilities.supportsCustomExposure ? "YES" : "NO")
                        debugRow("Focus lock", capabilities.supportsFocusLock ? "YES" : "NO")
                        debugRow("White balance lock", capabilities.supportsWhiteBalanceLock ? "YES" : "NO")
                        debugRow("Lens stabilization", capabilities.supportsLensStabilization ? "YES" : "NO")
                        debugRow("Active format", capabilities.activeFormat)
                    } else {
                        Text("Capabilities are read when the native camera starts.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                    if let plan = diagnostics.plan {
                        debugRow("Selected Capture Profile", plan.profile.devLabel)
                        debugRow("Ladder", plan.exposureValues.map(String.init).joined(separator: " "))
                        debugRow("Bracket requests", plan.segmentDescription)
                        Text(plan.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(VE.textTertiary)
                    }
                }
                .listRowBackground(VE.surface)

                Section("Last bracket") {
                    if let manifest = diagnostics.lastManifest {
                        debugRow("Client Capture ID", String(manifest.clientCaptureID.uuidString.prefix(8)))
                        debugRow("Capture Profile", manifest.captureProfile.devLabel)
                        debugRow("Expected Frames", "\(manifest.expectedFrameCount)")
                        debugRow("Captured Frames", "\(manifest.actualFrameCount)")
                        debugRow("Bundle state", manifest.state.devLabel)
                        debugRow("Orientation", manifest.orientation.devLabel)
                        debugRow("Focus lock", manifest.focusLockSucceeded.devLabel)
                        debugRow("White balance lock", manifest.whiteBalanceLockSucceeded.devLabel)
                        debugRow("Bracket duration", manifest.bracketDurationDescription)
                        debugRow("First frame", seconds(manifest.firstFrameSeconds))
                        debugRow("Local persistence", seconds(manifest.persistSeconds))
                        debugRow("Manifest", seconds(manifest.manifestSeconds))
                        debugRow("Total local size", manifest.totalSizeDescription)
                        if let failureCode = manifest.failureCode {
                            debugRow("Failure", failureCode)
                        }
                        NavigationLink {
                            DevFrameInspectorView(manifest: manifest)
                        } label: {
                            Text("Frame inspector · \(manifest.frames.count) exposures")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(VE.copper)
                        }
                    } else {
                        Text("No native bracket captured in this run.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                    if let file = diagnostics.lastFile {
                        debugRow("Reference frame", file.fileName)
                        debugRow("Image dimensions", file.pixelDescription)
                        debugRow("Displayed as", file.displayDescription)
                        debugRow("EXIF orientation", "\(file.exifOrientation)")
                        debugRow("File size", file.sizeDescription)
                        debugRow("Local file path", CaptureFileStore.path(for: file))
                    }
                    if let duration = diagnostics.captureDurationDescription {
                        debugRow("Capture duration", duration)
                    }
                }
                .listRowBackground(VE.surface)

                Section("Last capture") {
                    if let capture = state.lastCapture, let property = state.property(capture.propertyID) {
                        debugRow("Property", property.title)
                        debugRow("Room", state.roomName(capture.room))
                        debugRow("Capture ID", capture.shortID)
                        debugRow("Client Capture ID", String(capture.clientCaptureID.uuidString.prefix(8)))
                        debugRow("Camera Mode", diagnostics.mode.devLabel)
                        debugRow("Capture State", state.captureStageLabel)
                        debugRow("Capture Source", capture.captureSource.devLabel)
                        debugRow("HDR Source", capture.hdrSource.devLabel)
                        debugRow("Frames", "\(capture.frameCount)")
                        debugRow("Processing State", capture.jobState.rawValue)
                        debugRow("User Status", state.t(capture.status.localizationKey))
                        debugRow("Asset State", capture.assets.map(\.type.rawValue).joined(separator: " → "))
                        debugRow("Local Original", capture.hasLocalOriginal ? "true" : "false")
                        if let file = capture.localFile {
                            debugRow("Local file", file.fileName)
                        }
                        debugRow("Pending Sync", capture.isPendingSync ? "true" : "false")
                    } else {
                        debugRow("Capture State", state.captureStageLabel)
                        Text("No capture registered in this session.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                    debugRow("Preparing queue", "\(state.preparingCount)")
                    debugRow("Pending uploads", "\(state.pendingSyncCount)")
                }
                .listRowBackground(VE.surface)

                Section("Development properties") {
                    if developmentProperties.isEmpty {
                        Text("No development property registered.")
                            .font(.system(size: 13))
                            .foregroundStyle(VE.textTertiary)
                    }
                    ForEach(developmentProperties) { property in
                        debugRow("Property", property.title)
                        debugRow("Property Type", property.type.rawValue.uppercased())
                        debugRow("Status", property.lifecycle.devLabel)
                        if let asset = property.sourceAsset {
                            debugRow("Source Asset", asset.fileName)
                            debugRow("Source Type", asset.format.label)
                            debugRow("source_asset_type", asset.format.rawValue)
                            debugRow("Original Asset", asset.isImmutable ? "IMMUTABLE" : "MUTABLE")
                            debugRow("Feeds Camera", asset.canFeedCamera ? "true" : "false")
                            debugRow("Derivatives", asset.derivativeSummary)
                        }
                        debugRow("Captures", "\(state.captures(for: property.id).count)")
                    }
                }
                .listRowBackground(VE.surface)

                Section("Subscription") {
                    Picker("Plan", selection: planBinding) {
                        ForEach(PlanID.allCases) { plan in
                            Text(plan.shortName).tag(plan)
                        }
                    }
                    Picker("Status", selection: statusBinding) {
                        ForEach(SubscriptionStatus.allCases) { status in
                            Text(status.label).tag(status)
                        }
                    }
                    Picker("Payment channel", selection: channelBinding) {
                        ForEach(PaymentChannel.allCases) { channel in
                            Text(channel.label).tag(channel)
                        }
                    }
                }
                .listRowBackground(VE.surface)

                Section("AI credits") {
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text("\(state.wallet.total)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(VE.ai)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(creditPresets, id: \.self) { value in
                                Button("\(value)") {
                                    state.devSetCredits(included: value, purchased: 0)
                                }
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(VE.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(VE.elevated, in: .capsule)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    HStack {
                        Button("Included +10") {
                            state.devSetCredits(included: state.wallet.includedCredits + 10, purchased: state.wallet.purchasedCredits)
                        }
                        Spacer()
                        Button("Purchased +25") {
                            state.devSetCredits(included: state.wallet.includedCredits, purchased: state.wallet.purchasedCredits + 25)
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(VE.ai)
                }
                .listRowBackground(VE.surface)

                Section("Connectivity") {
                    Toggle("Online", isOn: onlineBinding)
                        .tint(VE.success)
                    Picker("Sync", selection: syncBinding) {
                        Text("Synced").tag(SyncState.synced)
                        Text("Pending").tag(SyncState.pending)
                        Text("Uploading").tag(SyncState.uploading)
                        Text("Offline").tag(SyncState.offline)
                    }
                }
                .listRowBackground(VE.surface)

                Section("Capture states") {
                    Button("All ready") { state.devSetJobState(.ready, all: true) }
                    Button("All preparing") { state.devSetJobState(.processing, all: true) }
                    Button("One failed") { state.devSetJobState(.failed, all: false) }
                    Button("Needs recapture") { state.devSetJobState(.needsReview, all: false) }
                }
                .listRowBackground(VE.surface)
                .foregroundStyle(VE.textPrimary)

                Section("Local capture storage") {
                    debugRow("Capture bundles", "\(bundles.count)")
                    debugRow("Valid bundles", "\(bundles.filter { $0.state.isValid }.count)")
                    debugRow("Incomplete bundles", "\(bundles.filter { !$0.state.isValid }.count)")
                    debugRow("Total on disk", totalStorageDescription)
                    Button("Restore pending captures") { state.restorePendingCaptures() }
                    Button("Clean up incomplete (7+ days)") {
                        CaptureBundleStore.cleanupIncomplete()
                    }
                }
                .listRowBackground(VE.surface)
                .foregroundStyle(VE.textPrimary)

                Section("Portfolio") {
                    Button("Empty portfolio") { state.properties = [] }
                    Button("Reset mock data") { state.devReset() }
                }
                .listRowBackground(VE.surface)
                .foregroundStyle(VE.textPrimary)

                Section("Feature flags") {
                    flag("camera_native_enabled", state.cameraMode.isNative)
                    flag("hdr_processing_enabled", FeatureFlags.hdrProcessingEnabled)
                    flag("ai_tools_enabled", FeatureFlags.aiToolsEnabled)
                    flag("billing_enabled", FeatureFlags.billingEnabled)
                    flag("credit_purchase_enabled", FeatureFlags.creditPurchaseEnabled)
                }
                .listRowBackground(VE.surface)
            }
            .scrollContentBackground(.hidden)
            .background(VE.canvas)
            .navigationTitle(state.t("settings.dev"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(state.t("common.close")) { dismiss() }
                        .foregroundStyle(VE.textSecondary)
                }
            }
        }
        .fullScreenCover(item: $screen) { item in
            DevScreenHost(screen: item)
        }
        .preferredColorScheme(.dark)
    }

    private func open(_ item: DevScreen) {
        if item == .offlineCapture {
            state.setOnline(false)
        }
        screen = item
    }

    // MARK: - Derived

    private var diagnostics: CameraDiagnostics { state.cameraDiagnostics }

    private var developmentProperties: [Property] {
        state.properties.filter(\.isDevelopmentProperty)
    }

    private var bundles: [CaptureManifest] { CaptureBundleStore.allManifests() }

    private var totalStorageDescription: String {
        let bytes = bundles.reduce(0) { $0 + $1.totalByteCount }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f s", value)
    }

    // MARK: - Bindings

    private var cameraModeBinding: Binding<CameraMode> {
        Binding(
            get: { state.cameraMode },
            set: { mode in
                state.cameraMode = mode
                state.cameraDiagnostics.mode = mode
            }
        )
    }

    private var regionBinding: Binding<RegionCode> {
        Binding(get: { state.regionCode }, set: { state.selectRegion($0) })
    }

    private var resultBinding: Binding<CaptureResultMode> {
        Binding(get: { state.captureResultMode }, set: { state.captureResultMode = $0 })
    }

    private var delayBinding: Binding<Double> {
        Binding(get: { state.preparationSeconds }, set: { state.preparationSeconds = $0 })
    }

    private var planBinding: Binding<PlanID> {
        Binding(get: { state.subscription.planID }, set: { state.subscription.planID = $0 })
    }

    private var statusBinding: Binding<SubscriptionStatus> {
        Binding(get: { state.subscription.status }, set: { state.subscription.status = $0 })
    }

    private var channelBinding: Binding<PaymentChannel> {
        Binding(get: { state.subscription.paymentChannel }, set: { state.subscription.paymentChannel = $0 })
    }

    private var onlineBinding: Binding<Bool> {
        Binding(get: { state.isOnline }, set: { state.setOnline($0) })
    }

    private var syncBinding: Binding<SyncState> {
        Binding(get: { state.syncState }, set: { state.syncState = $0 })
    }

    // MARK: - Helpers

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VE.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func flag(_ name: String, _ value: Bool) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(VE.textSecondary)
            Spacer()
            Text(value ? "ON" : "OFF")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(value ? VE.success : VE.textTertiary)
        }
    }
}

/// Renders one directly-opened screen for validation. Uses synthetic data where a
/// specific state is required, so the real portfolio is never mutated.
private struct DevScreenHost: View {
    let screen: DevScreen

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var property: Property {
        state.properties.first ?? MockData.properties()[0]
    }

    var body: some View {
        switch screen {
        case .cameraReady, .offlineCapture:
            CameraCaptureFlow(property: property, initialRoom: property.rooms.first ?? .living)
        case .cameraCapturing:
            CameraCaptureFlow(
                property: property,
                initialRoom: property.rooms.first ?? .living,
                previewCapturing: true
            )
        case .captureCompleted:
            CaptureCompletedView(
                capture: synthetic(.processing),
                property: property,
                onContinue: { dismiss() },
                onNextRoom: { dismiss() },
                onClose: { dismiss() }
            )
        case .galleryPreparing, .galleryReady, .galleryNeedsRecapture, .galleryError:
            let capture = synthetic(screen.jobState ?? .ready)
            PhotoDetailView(captureID: capture.id, onCapture: nil, previewCapture: capture)
        }
    }

    private func synthetic(_ jobState: ProcessingJobState) -> CaptureItem {
        let room = property.rooms.first ?? .living
        let createdAt = Date()
        return CaptureItem(
            id: UUID(),
            propertyID: property.id,
            room: room,
            image: room.placeholderImage,
            frameCount: 9,
            jobState: jobState,
            createdAt: createdAt,
            isFavorite: false,
            assets: MockData.lineage(frameCount: 9, createdAt: createdAt, includeMaster: jobState == .ready),
            isPendingSync: screen == .offlineCapture
        )
    }
}
