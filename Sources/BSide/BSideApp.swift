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
        // reference to it. Deferred a runloop turn: forcing `NSApplication`
        // into existence synchronously inside `App.init()` raced SwiftUI's
        // own app-menu construction (the one that inserts the automatic
        // "Settings…"/Cmd+, item for the `Settings` scene below) and could
        // leave the App menu malformed. Dispatching it lets SwiftUI finish
        // building its default menu first.
        DispatchQueue.main.async {
            NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance
        }

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
        // `.contentMinSize`, not `.contentSize`: the latter constrains the
        // window to its content's size in both directions, which fights the
        // user resizing a window whose whole point is three resizable
        // regions. This takes only the floor from `ContentView`'s frame.
        .windowResizability(.contentMinSize)
        .commands {
            // The `Settings` scene below is supposed to generate this item
            // (and its Cmd+, shortcut) automatically, but that only reliably
            // happens when a `Settings` scene's automatic app-menu wiring
            // hasn't been disturbed. Replacing `.appSettings` explicitly
            // makes the item unconditional rather than depending on that.
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(AppCommandShortcut.settings)
            }
            WindowLayoutCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
