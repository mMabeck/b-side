import AppKit

/// Routes Cmd/Ctrl key equivalents to `NSApp.mainMenu` *before* AppKit's
/// normal dispatch reaches a focused view, so a Ghostty terminal surface
/// never gets first say. `GhosttyBridge.appOwnedKeybinds` unbinds app
/// shortcuts from Ghostty's own keybind table, but under Pi's extended
/// keyboard reporting, `performKeyEquivalent`'s fallback still hands
/// Cmd/Ctrl keys to `keyDown` on the first call, bypassing the "decline"
/// path an unbind alone relies on. Since the surface-side logic is vendored
/// as a prebuilt `GhosttyKit.xcframework` and can't be inspected, this
/// routes independently: a local `NSEvent` monitor sees every keyDown
/// before `-[NSApplication sendEvent:]` dispatches it at all.
///
/// Keyed off "does `NSApp.mainMenu` claim this event", not a hardcoded
/// shortcut list, so it stays correct as SwiftUI `Commands` change. Routing
/// a standard Edit item (Copy/Paste/Select All) through the menu first
/// still ends up calling the same `AppTerminalView` action override, just via a different path.
@MainActor
public enum MainMenuKeyRouter {
    /// Never removed: the app has exactly one main menu for its lifetime. Call once, from `BSideApp.init()`.
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event) ? nil : event
        }
    }

    /// Split out from `install()`'s closure so it's directly testable against a real menu.
    @discardableResult
    static func route(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Restricted to Cmd/Ctrl: plain keystrokes a terminal needs (typed
        // text, arrows, ...) carry neither, so most keys never ask the menu at all.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return false }
        // `NSApplication.shared`, not `NSApp`: an implicitly-unwrapped optional not guaranteed set this early.
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
