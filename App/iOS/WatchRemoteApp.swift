import SwiftUI
import WatchRemoteCore

@main
struct WatchRemoteApp: App {
    @StateObject private var store = RemoteStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .tint(LojoTheme.accent)
        }
    }
}
