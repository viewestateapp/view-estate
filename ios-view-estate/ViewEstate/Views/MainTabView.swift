import SwiftUI

enum AppTab: Hashable {
    case home, properties, camera, gallery, ai
}

/// Shared tab chrome. Câmara is a prominent action: selecting it starts the capture
/// setup (property → room) and then presents the camera full screen, which conceals
/// the tab bar instead of pushing a flat tab.
struct MainTabView: View {
    @Environment(AppState.self) private var state

    @State private var selection: AppTab = .home
    @State private var lastSelection: AppTab = .home
    @State private var setup: CaptureSetupRequest?
    @State private var camera: CameraRequest?

    var body: some View {
        TabView(selection: tabBinding) {
            Tab(state.t("tab.home"), systemImage: "house.fill", value: AppTab.home) {
                HomeView(onCapture: startCapture)
            }
            Tab(state.t("tab.properties"), systemImage: "building.2", value: AppTab.properties) {
                PropertiesView(onCapture: startCapture)
            }
            Tab(state.t("tab.camera"), systemImage: "camera.fill", value: AppTab.camera) {
                Color.clear
            }
            Tab(state.t("tab.gallery"), systemImage: "photo.on.rectangle", value: AppTab.gallery) {
                GalleryView(onCapture: startCapture)
            }
            Tab(state.t("tab.ai"), systemImage: "sparkles", value: AppTab.ai) {
                AIToolsView()
            }
        }
        .tint(VE.copper)
        .sheet(item: $setup) { request in
            CaptureSetupSheet(
                initialProperty: request.property,
                suggestedRoom: request.suggestedRoom,
                currentRoom: request.currentRoom
            ) { property, room in
                openCamera(property: property, room: room)
            }
        }
        .fullScreenCover(item: $camera) { request in
            CameraCaptureFlow(property: request.property, initialRoom: request.room)
        }
    }

    private var tabBinding: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == .camera {
                    startCapture(property: nil, room: nil)
                    selection = lastSelection
                } else {
                    lastSelection = newValue
                    selection = newValue
                }
            }
        )
    }

    /// Entry point used by every surface. Missing pieces are asked for, never guessed.
    private func startCapture(property: Property?, room: RoomType?) {
        if let property, let room {
            openCamera(property: property, room: room)
            return
        }
        setup = CaptureSetupRequest(
            property: property,
            suggestedRoom: room ?? property?.rooms.first,
            currentRoom: nil
        )
    }

    private func openCamera(property: Property, room: RoomType) {
        setup = nil
        // Let the setup sheet finish dismissing before the full screen camera appears.
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            camera = CameraRequest(property: property, room: room)
        }
    }
}
