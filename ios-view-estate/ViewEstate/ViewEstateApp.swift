//
//  ViewEstateApp.swift
//  ViewEstate
//

import SwiftUI

@main
struct ViewEstateApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .preferredColorScheme(.dark)
        }
        // HDR processing belongs to the app, not to any screen: the app lifecycle drives
        // recovery of pending jobs on every return to the foreground.
        .onChange(of: scenePhase) { _, phase in
            state.handleScenePhase(phase)
        }
    }
}
