import AppKit

/// Routes Cmd/Ctrl key equivalents to `NSApp.mainMenu` *before* AppKit's
/// normal dispatch ever reaches a focused view — specifically, before a
/// Ghostty terminal surface gets a chance to decide for itself whether it
/// owns a key.
///
/// `GhosttyBridge.appOwnedKeybinds` unbinds the app's own shortcuts from
/// Ghostty's default keybind table, which is the right fix for the case
/// `AppTerminalView.performKeyEquivalent` documents: a key Ghostty's config
/// binds to a terminal action (`goto_tab`, `open_config`, ...) being
/// consumed by `ghostty_surface_key_is_binding` before AppKit's menu ever
/// sees it. It does not cover every path a key can take through the
/// surface, though — `performKeyEquivalent`'s fallback branch (for a key
/// that isn't a Ghostty binding at all) still hands Cmd/Ctrl-modified keys
/// to `keyDown` on the *first* call when a program running inside the
/// surface has requested extended keyboard reporting (Pi enables this), so
/// an unbound key equivalent can still never reach `performKeyEquivalent`'s
/// "decline, let the responder chain continue" path. Rather than depend on
/// the exact internal shape of that surface-side logic — unavailable to
/// inspect; `libghostty-spm` vendors it as a prebuilt `GhosttyKit.xcframework`
/// — this routes independently of it: an `NSEvent` local monitor sees every
/// keyDown before `-[NSApplication sendEvent:]` dispatches it to the key
/// window's responder chain at all, so it wins regardless of what the
/// terminal surface would have done with the same event.
///
/// Deliberately keyed off "does `NSApp.mainMenu` claim this event", not a
/// hardcoded shortcut list: every shortcut this needs to protect (Cmd+1…9,
/// Ctrl+1…9, Cmd+B, Cmd+Opt+B, Cmd+Æ, Cmd+N, Cmd+Shift+N, Cmd+,, Cmd+W, ...)
/// already exists as a real `NSMenuItem` key equivalent via SwiftUI's
/// `Commands`/`.keyboardShortcut`, so asking the menu directly stays correct
/// as those commands change without this file needing to track them by
/// hand. `performKeyEquivalent(with:)` both recognizes *and acts on* a
/// matching item — for a standard Edit menu entry (Copy, Paste, Select
/// All, ...) that means sending the same `copy:`/`paste:`/`selectAll:`
/// action the terminal's own `AppTerminalView` overrides already handle, so
/// routing through the menu first doesn't change what Cmd+C/Cmd+V/Cmd+A do
/// inside a terminal — only *how* the call reaches the same override.
@MainActor
public enum MainMenuKeyRouter {
    /// Installs the local monitor once for the app's lifetime — never
    /// removed, since the app has exactly one main menu for as long as it
    /// runs. Call once, from `BSideApp.init()`.
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event) ? nil : event
        }
    }

    /// `true` if `NSApp.mainMenu` claimed (and acted on) `event` as one of
    /// its key equivalents — callers should swallow the event in that case,
    /// per `install()`. Split out from `install()`'s closure so it's
    /// directly testable against a real menu without going through an
    /// actual `NSEvent` monitor.
    @discardableResult
    static func route(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Restricted to Cmd/Ctrl-modified keys: every shortcut this exists
        // to protect carries one of those two, and every plain keystroke a
        // terminal needs (typed text, arrow keys, ...) carries neither, so
        // this never even asks the menu about the vast majority of keys a
        // terminal receives.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return false }
        // `NSApplication.shared`, not the `NSApp` global: per `BSideApp.init()`'s
        // own doc comment, `NSApp` is an implicitly-unwrapped optional not
        // guaranteed set this early (or, for a headless test host, at all).
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
