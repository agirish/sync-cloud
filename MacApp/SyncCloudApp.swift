import SwiftUI

@main
struct SyncCloudApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Logger.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
} 