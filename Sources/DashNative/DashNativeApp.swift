import DashNativeKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "ai.syv.dash-native", category: "app")

@main
struct DashNativeApp: App {
    private let store: ProjectsStore

    init() {
        do {
            let database = try AppDatabase.openStandard()
            store = ProjectsStore(database: database)
        } catch {
            logger.fault("Failed to open database: \(error, privacy: .public)")
            fatalError("Failed to open database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }

        Settings {
            SettingsView()
        }
        .commands {
            WindowLayoutCommands()
        }
    }
}
