import AppKit
import Testing

@testable import BSideKit

/// Exercises `MainMenuKeyRouter.route(_:)` against a real `NSMenu` set as
/// `NSApplication.shared.mainMenu` — no synthetic desktop keystrokes, just the same
/// `NSMenu.performKeyEquivalent(with:)` call the router itself makes. Covers
/// the guarantee `BSideApp` relies on: a key equivalent one of the app's
/// real `Commands` claims fires even when asked directly, independent of
/// whatever a focused Ghostty terminal surface would have done with the
/// same event, and a key nothing claims (or one with no modifier at all)
/// is left alone for the terminal to handle as before.
@MainActor
@Suite("MainMenuKeyRouter")
struct MainMenuKeyRouterTests {
    @Test("A Cmd-key matching a main menu item is claimed and fires the item's action")
    func routesAndFiresMatchingKey() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        let target = ActionRecorder()
        NSApplication.shared.mainMenu = Self.menu(keyEquivalent: "1", modifiers: [.command], target: target)

        let event = try Self.keyEvent(characters: "1", modifiers: [.command])
        #expect(MainMenuKeyRouter.route(event))
        #expect(target.fired)
    }

    @Test("A Ctrl-key matching a main menu item is claimed the same way")
    func routesMatchingCtrlKey() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        let target = ActionRecorder()
        NSApplication.shared.mainMenu = Self.menu(keyEquivalent: "1", modifiers: [.control], target: target)

        let event = try Self.keyEvent(characters: "1", modifiers: [.control])
        #expect(MainMenuKeyRouter.route(event))
        #expect(target.fired)
    }

    @Test("A key with no matching main menu item is left for the terminal")
    func declinesUnmatchedKey() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        let target = ActionRecorder()
        NSApplication.shared.mainMenu = Self.menu(keyEquivalent: "1", modifiers: [.command], target: target)

        // Same modifier, different character: nothing in the menu claims "2".
        let event = try Self.keyEvent(characters: "2", modifiers: [.command])
        #expect(!MainMenuKeyRouter.route(event))
        #expect(!target.fired)
    }

    @Test("A plain, unmodified key is never even asked about — the terminal's own keystrokes are untouched")
    func ignoresUnmodifiedKeys() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        // A menu item with no key equivalent modifiers at all would still
        // theoretically match plain "c", so this proves the router's own
        // modifier gate — not an empty menu — is what declines it.
        let target = ActionRecorder()
        let item = NSMenuItem(title: "Bogus", action: #selector(ActionRecorder.act), keyEquivalent: "c")
        item.keyEquivalentModifierMask = []
        item.target = target
        let submenu = NSMenu()
        submenu.addItem(item)
        let submenuItem = NSMenuItem()
        submenuItem.submenu = submenu
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem)
        NSApplication.shared.mainMenu = mainMenu

        let event = try Self.keyEvent(characters: "c", modifiers: [])
        #expect(!MainMenuKeyRouter.route(event))
        #expect(!target.fired)
    }

    private static func menu(keyEquivalent: String, modifiers: NSEvent.ModifierFlags, target: ActionRecorder) -> NSMenu {
        let item = NSMenuItem(title: "Test Action", action: #selector(ActionRecorder.act), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        let submenu = NSMenu()
        submenu.addItem(item)
        let submenuItem = NSMenuItem()
        submenuItem.submenu = submenu
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem)
        return mainMenu
    }

    private static func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}

private final class ActionRecorder: NSObject {
    private(set) var fired = false
    @objc func act() { fired = true }
}
