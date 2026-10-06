import RedlineCore
import SwiftUI
import UIKit

@main
struct RedlineApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.launch() }
                .onChange(of: scenePhase) { _, phase in model.handleScenePhase(phase) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "speedometer") }
            ConnectView()
                .tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
            DebugView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .tint(Theme.redline)
        .onChange(of: model.engine.state.isStreaming, initial: true) { _, streaming in
            UIApplication.shared.isIdleTimerDisabled = streaming && model.settings.keepScreenAwake
        }
    }
}
