import SwiftUI

/// Formats a `KeyboardShortcut` into the glyphs macOS menus use (⌃⌥⇧⌘ in
/// that fixed order) and into words for VoiceOver.
public enum KeyboardShortcutGlyph {
    public static func symbols(for shortcut: KeyboardShortcut) -> String {
        modifierGlyphs(shortcut.modifiers) + keyGlyph(shortcut.key)
    }

    public static func accessibilityLabel(for shortcut: KeyboardShortcut) -> String {
        (modifierWords(shortcut.modifiers) + [keyWord(shortcut.key)]).joined(separator: " ")
    }

    private static func modifierGlyphs(_ modifiers: EventModifiers) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    private static func modifierWords(_ modifiers: EventModifiers) -> [String] {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return words
    }

    private static func keyGlyph(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .return: "⏎"
        default: String(key.character).uppercased()
        }
    }

    private static func keyWord(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .leftArrow: "Left Arrow"
        case .rightArrow: "Right Arrow"
        case .return: "Return"
        default: String(key.character).uppercased()
        }
    }
}

/// Built from the same shortcut constants the real `Commands` use so this
/// list can't drift from what the menu bar actually binds.
public struct KeybindingRow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbols: String
    public let accessibilityLabel: String

    public init(title: String, shortcut: KeyboardShortcut) {
        self.id = title
        self.title = title
        self.symbols = KeyboardShortcutGlyph.symbols(for: shortcut)
        self.accessibilityLabel = KeyboardShortcutGlyph.accessibilityLabel(for: shortcut)
    }

    /// For a collapsed digit series (e.g. "⌘1…⌘9") where no single `KeyboardShortcut` applies.
    public init(title: String, symbols: String, accessibilityLabel: String) {
        self.id = title
        self.title = title
        self.symbols = symbols
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct KeybindingSection: Identifiable, Sendable {
    public let id: String
    public let rows: [KeybindingRow]

    public init(title: String, rows: [KeybindingRow]) {
        self.id = title
        self.rows = rows
    }

    public var title: String { id }
}

/// The full reference list shown in Settings > Keybindings.
public enum KeybindingsReference {
    public static let sections: [KeybindingSection] = [
        KeybindingSection(title: "Projects & Tasks", rows: [
            KeybindingRow(title: "New Task", shortcut: ProjectCommandShortcut.newTask),
            KeybindingRow(title: "Add Project…", shortcut: ProjectCommandShortcut.addProject),
        ]),
        KeybindingSection(title: "Navigation", rows: [
            digitSeriesRow(
                title: "Switch to Active Task 1–9",
                count: NavigationShortcuts.digitCount,
                shortcut: { NavigationShortcuts.activeTaskShortcut(forIndex: $0) }
            ),
            digitSeriesRow(
                title: "Switch to Project 1–9",
                count: NavigationShortcuts.digitCount,
                shortcut: { NavigationShortcuts.projectShortcut(forIndex: $0) }
            ),
        ]),
        KeybindingSection(title: "Window Layout", rows: [
            KeybindingRow(title: "Show/Hide Left Sidebar", shortcut: WindowLayoutShortcut.leftSidebar),
            KeybindingRow(title: "Show/Hide Right Sidebar", shortcut: WindowLayoutShortcut.rightSidebar),
            KeybindingRow(title: "Show/Hide Terminal", shortcut: WindowLayoutShortcut.terminalDrawer),
        ]),
        KeybindingSection(title: "Terminal", rows: [
            KeybindingRow(title: "Close Task Terminal", shortcut: TerminalCloseShortcut.closeTask),
            KeybindingRow(title: "Restart Pi Session", shortcut: TerminalCloseShortcut.restartSession),
            KeybindingRow(title: "Open in VS Code", shortcut: EditorShortcut.openInEditor),
        ]),
        KeybindingSection(title: "Subagents", rows: [
            KeybindingRow(title: "Show Main Terminal", shortcut: SubagentSwapShortcut.showMain),
            digitSeriesRow(
                title: "Show Subagent 1–9",
                count: SubagentSwapShortcut.digitCount,
                shortcut: { SubagentSwapShortcut.showChild(atIndex: $0) }
            ),
            dualShortcutRow(title: "Next Subagent", primary: SubagentSwapShortcut.next, alternate: SubagentSwapShortcut.nextArrow),
            dualShortcutRow(title: "Previous Subagent", primary: SubagentSwapShortcut.previous, alternate: SubagentSwapShortcut.previousArrow),
        ]),
        KeybindingSection(title: "Changes", rows: [
            KeybindingRow(title: "Show All Changes", shortcut: ChangesOverlayShortcut.showAllChanges),
        ]),
    ]

    /// The first and last shortcut in a 1…9 digit series share the same
    /// modifiers, so their glyphs differ only in the digit — safe to splice
    /// into one "⌘1…⌘9" string instead of listing all nine.
    private static func digitSeriesRow(title: String, count: Int, shortcut: (Int) -> KeyboardShortcut) -> KeybindingRow {
        let first = shortcut(0)
        let last = shortcut(count - 1)
        let symbols = "\(KeyboardShortcutGlyph.symbols(for: first))…\(KeyboardShortcutGlyph.symbols(for: last))"
        let label = "\(KeyboardShortcutGlyph.accessibilityLabel(for: first)) through \(KeyboardShortcutGlyph.accessibilityLabel(for: last))"
        return KeybindingRow(title: title, symbols: symbols, accessibilityLabel: label)
    }

    /// Some actions register two shortcuts (e.g. `]`/`⌃⌘→`); show both on one row.
    private static func dualShortcutRow(title: String, primary: KeyboardShortcut, alternate: KeyboardShortcut) -> KeybindingRow {
        let symbols = "\(KeyboardShortcutGlyph.symbols(for: primary)) or \(KeyboardShortcutGlyph.symbols(for: alternate))"
        let label = "\(KeyboardShortcutGlyph.accessibilityLabel(for: primary)) or \(KeyboardShortcutGlyph.accessibilityLabel(for: alternate))"
        return KeybindingRow(title: title, symbols: symbols, accessibilityLabel: label)
    }
}
