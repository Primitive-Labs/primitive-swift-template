import SwiftUI
import PrimitiveApp

struct ContentView: View {
    @EnvironmentObject var appState: PrimitiveAppState

    var body: some View {
        AuthGateView(appName: "Primitive Template", authManager: appState.authManager) {
            AppTabView()
        }
        .task {
            await appState.initialize()
        }
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}

struct AppTabView: View {
    @EnvironmentObject var appState: PrimitiveAppState

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                DocumentsView()
            }
            .tabItem { Label("Documents", systemImage: "doc.text") }

            NavigationStack {
                PrimitiveProfileView(authManager: appState.authManager)
            }
            .tabItem { Label("Profile", systemImage: "person.circle") }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var appState: PrimitiveAppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Welcome, \(appState.userName)")
                .font(.title2)
            Text("Build your app here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
    }
}

struct DocumentsView: View {
    @EnvironmentObject var appState: PrimitiveAppState

    var body: some View {
        if appState.documents.isEmpty && !appState.isLoadingDocs {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No documents")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Documents")
        } else {
            List(appState.documents, selection: $appState.selectedDocId) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                    Text(doc.id.prefix(16) + "...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
                .tag(doc.id)
                .padding(.vertical, 2)
            }
            .navigationTitle("Documents")
            .onChange(of: appState.selectedDocId) { _, newValue in
                if let docId = newValue {
                    appState.selectDocument(docId)
                }
            }
        }
    }
}
