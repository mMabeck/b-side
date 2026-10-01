import AppKit
import BSideKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.mabeck.bside", category: "app")

@main
struct BSideApp: App {
    private let store: ProjectsStore

    init() {
        // Resolved before any window is built, or windows with no terminal (Settings, New Task) keep the light `.fallback` palette.
        GhosttyResolvedTheme.resolveEagerly()
        // `NSApplication.shared`, not `NSApp`, which may be unset this early. Set synchronously: deferring risks a light-appearance flash on the first frame.
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance

        // Menu shortcuts must fire while a Ghostty terminal is first responder; see `MainMenuKeyRouter`.
        MainMenuKeyRouter.install()
        TerminalScrollRouter.install()

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
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        // `.contentMinSize`, not `.contentSize`, which fights the user resizing the window.
        .windowResizability(.contentMinSize)
        .commands {
            // Don't add `CommandGroup(replacing: .appSettings)`: the `Settings` scene already generates that item, and it would duplicate rather than replace it.
            WindowLayoutCommands(store: store)
            ProjectCommands(store: store)
            EditorCommands(store: store)
            NavigationCommands(store: store)
            TerminalCommands(store: store)
            SubagentSwapCommands(store: store)
            ChangesCommands(store: store)
        }

        Settings {
            SettingsView()
        }
    }
}
