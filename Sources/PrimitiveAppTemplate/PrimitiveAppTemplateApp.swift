import SwiftUI
import PrimitiveApp

#if os(macOS)
import AppKit
#endif

@main
struct PrimitiveAppTemplateApp: App {
    @StateObject private var appState = PrimitiveAppState()

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
