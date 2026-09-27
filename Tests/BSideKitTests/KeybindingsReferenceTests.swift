import SwiftUI
import Testing

@testable import BSideKit

@Suite("Keybinding glyph formatting")
struct KeybindingsReferenceTests {
    @Test(
        "Formats modifiers in fixed macOS order and renders special keys as glyphs/words",
        arguments: [
            (KeyboardShortcut("n", modifiers: [.command, .shift]), "⇧⌘N", "Shift Command N"),
            (KeyboardShortcut("b", modifiers: [.control, .option, .shift, .command]), "⌃⌥⇧⌘B", "Control Option Shift Command B"),
            (KeyboardShortcut(.rightArrow, modifiers: [.control, .command]), "⌃⌘→", "Control Command Right Arrow"),
        ]
    )
    func formatsShortcut(shortcut: KeyboardShortcut, symbols: String, label: String) {
        #expect(KeyboardShortcutGlyph.symbols(for: shortcut) == symbols)
        #expect(KeyboardShortcutGlyph.accessibilityLabel(for: shortcut) == label)
    }
}
