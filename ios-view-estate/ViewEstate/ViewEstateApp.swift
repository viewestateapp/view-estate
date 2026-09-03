//
//  ViewEstateApp.swift
//  ViewEstate
//

import SwiftUI

@main
struct ViewEstateApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .preferredColorScheme(.dark)
        }
    }
}
