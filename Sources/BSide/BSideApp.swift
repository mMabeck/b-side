import AppKit
import BSideKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "ai.syv.bside", category: "app")

@main
struct BSideApp: App {
    private let store: ProjectsStore

    init() {
        // Resolved before any window is built: without this, the palette
        // stays `.fallback` (light system colours) until a terminal surface
        // happens to construct one, which never occurs at all for windows
        // like Settings or the New Task sheet that host no terminal.
        GhosttyResolvedTheme.resolveEagerly()
        // `NSApplication.shared`, not the `NSApp` global: `NSApp` is an
        // implicitly-unwrapped optional that is not guaranteed set this
        // early in the SwiftUI `App` lifecycle — `.shared` lazily creates
        // the application instance instead of force-unwrapping a possibly-nil
        // reference to it.
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance

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
