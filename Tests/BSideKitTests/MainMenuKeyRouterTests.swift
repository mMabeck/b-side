import AppKit
import Testing

@testable import BSideKit

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

        let event = try Self.keyEvent(characters: "2", modifiers: [.command])
        #expect(!MainMenuKeyRouter.route(event))
        #expect(!target.fired)
    }

    @Test("A plain, unmodified key is never even asked about — the terminal's own keystrokes are untouched")
    func ignoresUnmodifiedKeys() throws {
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        // With no modifiers a menu item could match plain "c", so this proves the router's own modifier gate declines it.
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
