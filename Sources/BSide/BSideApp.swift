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
        // reference to it. Set synchronously (a prior deferral, added on a
        // theory that this raced SwiftUI's app-menu construction, was
        // disproved by a menu-dump diagnostic — the same menu resulted
        // either way): deferring risks a light-appearance flash on the
        // first frame.
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance

        // Cmd+1…9/Ctrl+1…9/Cmd+B/etc. must fire even while a Ghostty terminal
        // running Pi is first responder — see `MainMenuKeyRouter`'s doc comment
        // for why `GhosttyBridge.appOwnedKeybinds` alone isn't enough.
        MainMenuKeyRouter.install()
        // Trackpad scrolling at Ghostty.app's speed — see `TerminalScrollRouter`.
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
        // `.contentMinSize`, not `.contentSize`: the latter constrains the
        // window to its content's size in both directions, which fights the
        // user resizing a window whose whole point is three resizable
        // regions. This takes only the floor from `ContentView`'s frame.
        .windowResizability(.contentMinSize)
        .commands {
            // The `Settings` scene below already generates the App menu's
            // "Settings…" item and its Cmd+, shortcut automatically. Do not
            // add `CommandGroup(replacing: .appSettings)` here: it duplicates
            // that item rather than replacing it, and neither copy opens a
            // window.
            WindowLayoutCommands()
            ProjectCommands(store: store)
            EditorCommands(store: store)
            NavigationCommands(store: store)
            TerminalCommands(store: store)
            SubagentSwapCommands(store: store)
        }

        Settings {
            SettingsView()
        }
    }
}
