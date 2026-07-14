import SwiftUI

@main
struct RemoteDesktopApp: App {
    @StateObject private var session = SessionModel()
    @StateObject private var computerUseSetup = ComputerUseSetupCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(computerUseSetup)
        }
    }
}
