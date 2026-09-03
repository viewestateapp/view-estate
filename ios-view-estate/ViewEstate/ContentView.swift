//
//  ContentView.swift
//  ViewEstate
//

import SwiftUI

/// Where the app is before a session exists.
enum AuthRoute: Hashable {
    case welcome
    case signIn
    case onboarding
}

/// Root router: the brand welcome owns the first launch, sign-in and account creation
/// sit on top of it, and the shared tab chrome takes over once a session exists.
struct ContentView: View {
    @Environment(AppState.self) private var state

    @State private var route: AuthRoute = .welcome

    var body: some View {
        ZStack {
            VE.canvas.ignoresSafeArea()

            if state.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                authSurface
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.isAuthenticated)
        .onChange(of: state.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated { route = .welcome }
        }
    }

    @ViewBuilder
    private var authSurface: some View {
        switch route {
        case .welcome:
            WelcomeView(
                onSignIn: { go(.signIn) },
                onCreateAccount: { go(.onboarding) }
            )
            .transition(.opacity)
        case .signIn:
            SignInView(
                onSignedIn: {},
                onCreateAccount: { go(.onboarding) },
                onCancel: { go(.welcome) }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case .onboarding:
            OnboardingFlow(
                onFinished: {},
                onCancel: { go(.welcome) }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func go(_ next: AuthRoute) {
        withAnimation(.easeInOut(duration: 0.3)) { route = next }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
