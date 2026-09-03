//
//  ContentView.swift
//  ViewEstate
//

import SwiftUI

/// Root router: the brand welcome owns the first launch, then the shared tab chrome.
struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            VE.canvas.ignoresSafeArea()

            if state.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.isAuthenticated)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
