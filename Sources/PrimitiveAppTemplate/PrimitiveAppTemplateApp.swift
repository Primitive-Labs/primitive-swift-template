import SwiftUI
import PrimitiveApp

#if os(macOS)
import AppKit
#endif

@main
struct PrimitiveAppTemplateApp: App {
    // `TemplateAppState` is a subclass of `PrimitiveAppState` that
    // adds the per-user singleton-doc setup and model loading.
    // See TemplateAppState.swift. Replace with your own subclass when
    // you customize the data model.
    @StateObject private var appState = TemplateAppState()

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
