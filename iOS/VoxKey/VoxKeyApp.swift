import SwiftUI

@main
struct VoxKeyApp: App {
    @StateObject private var manager = BackgroundAudioManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
