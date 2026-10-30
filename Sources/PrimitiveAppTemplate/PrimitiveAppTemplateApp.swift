import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct PrimitiveAppTemplateApp: App {
    // The app's state: the client, sign-in, the profile and the db3s the app
    // reads. See App/AppState.swift.
    @StateObject private var appState = AppState()

    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("Primitive") {
            ContentView()
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 700, minHeight: 500)
                #endif
        }
    }
}
