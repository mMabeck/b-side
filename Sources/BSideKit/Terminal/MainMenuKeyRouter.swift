import AppKit

/// Routes Cmd/Ctrl key equivalents to `NSApp.mainMenu` before a focused Ghostty surface sees them.
/// Under Pi's extended keyboard reporting `performKeyEquivalent` hands Cmd/Ctrl keys to `keyDown`, so the unbinds in
/// `GhosttyBridge.appOwnedKeybinds` alone aren't enough. Keyed off whether the menu claims the event, not a hardcoded list.
@MainActor
public enum MainMenuKeyRouter {
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event) ? nil : event
        }
    }

    @discardableResult
    static func route(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Plain keystrokes a terminal needs carry neither modifier, so they never ask the menu.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return false }
        // `NSApplication.shared`, not `NSApp`: an implicitly-unwrapped optional not guaranteed set this early.
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
