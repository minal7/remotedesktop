import SwiftUI

@main
struct RemoteDesktopApp: App {
    @StateObject private var session = SessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
