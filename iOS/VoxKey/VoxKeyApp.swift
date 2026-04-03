import SwiftUI

@main
struct HushTypeApp: App {
    @StateObject private var manager = BackgroundAudioManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
