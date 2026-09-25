import SwiftUI

/// Menu commands for swapping the selected task's main area between the
/// parent Pi terminal and a child subagent's surface. `⌃⌘0` shows the
/// parent; `⌃⌘1`…`⌃⌘9` show the Nth child in strip order; `⌃⌘]`/`⌃⌘[` step
/// forward/back through the strip (wrapping through the parent at either
/// end). Mirrors `TerminalCommands`'/`NavigationCommands`'s pattern of a
/// `Commands` struct driving a per-window `ProjectsStore`.
///
/// `⌃⌘`-modified keys reach here even when a terminal surface has focus:
/// `MainMenuKeyRouter` intercepts every Cmd/Ctrl-modified `keyDown` ahead of
/// AppKit's normal dispatch and asks `NSApp.mainMenu` to handle it first,
/// which is exactly what a real `Commands`/`.keyboardShortcut` item like
/// these registers as — the same mechanism `TerminalCommands`' Cmd+Shift+R
/// relies on. No `GhosttyBridge.appOwnedKeybinds` entry is needed for this
/// modifier combination: Ghostty's default keybind table has no
/// `ctrl+cmd+<digit>`/`ctrl+cmd+]`/`ctrl+cmd+[` bindings to unbind, and
/// `MainMenuKeyRouter` wins regardless of what the surface would have done.
public struct SubagentSwapCommands: Commands {
    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandMenu("Subagents") {
            Button("Show Main Terminal") {
                withSelectedTask { store.subagentSwap.showMain(forTask: $0) }
            }
            .keyboardShortcut(SubagentSwapShortcut.showMain)

            Divider()

            ForEach(0..<SubagentSwapShortcut.digitCount, id: \.self) { index in
                Button("Show Subagent \(index + 1)") {
                    withSelectedTask { taskId in
                        let strip = store.stripChildIDsWithLiveSurface(forTask: taskId)
                        guard let childId = SubagentSwapNavigation.childID(atIndex: index, strip: strip) else { return }
                        store.subagentSwap.show(childId: childId, forTask: taskId)
                    }
                }
                .keyboardShortcut(SubagentSwapShortcut.showChild(atIndex: index))
            }

            Divider()

            Button("Next Subagent") { advance(next: true) }
                .keyboardShortcut(SubagentSwapShortcut.next)

            Button("Previous Subagent") { advance(next: false) }
                .keyboardShortcut(SubagentSwapShortcut.previous)

            // Same two actions again, under the arrow-key equivalents
            // (`⌃⌘←`/`⌃⌘→`) — hidden from the menu so "Next"/"Previous
            // Subagent" above aren't listed twice, but still registered with
            // `NSApp.mainMenu` so `MainMenuKeyRouter` dispatches the arrow
            // form too. `⌃⌘[`/`⌃⌘]` need ⌥ on a Danish keyboard to type at
            // all, which the arrow keys don't.
            Button("Next Subagent (Arrow)") { advance(next: true) }
                .keyboardShortcut(SubagentSwapShortcut.nextArrow)
                .hidden()

            Button("Previous Subagent (Arrow)") { advance(next: false) }
                .keyboardShortcut(SubagentSwapShortcut.previousArrow)
                .hidden()
        }
    }

    private func advance(next: Bool) {
        withSelectedTask { taskId in
            let strip = store.stripChildIDsWithLiveSurface(forTask: taskId)
            let shown = store.subagentSwap.shownChildID(forTask: taskId)
            let target = next
                ? SubagentSwapNavigation.next(after: shown, strip: strip)
                : SubagentSwapNavigation.previous(before: shown, strip: strip)
            if let target {
                store.subagentSwap.show(childId: target, forTask: taskId)
            } else {
                store.subagentSwap.showMain(forTask: taskId)
            }
        }
    }

    private func withSelectedTask(_ action: (Int64) -> Void) {
        if case .task(let task, _) = store.mainSelection, let id = task.id {
            action(id)
        }
    }
}

/// The subagent-swap key equivalents, as plain data so they're directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `WindowLayoutShortcut`/`NavigationShortcuts`.
public enum SubagentSwapShortcut {
    public static let digitCount = 9

    public static let showMain = KeyboardShortcut("0", modifiers: [.control, .command])

    public static func showChild(atIndex index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
    }

    public static let next = KeyboardShortcut("]", modifiers: [.control, .command])
    public static let previous = KeyboardShortcut("[", modifiers: [.control, .command])

    /// Same actions as `next`/`previous`, under the arrow keys instead of
    /// brackets — a Danish keyboard layout needs ⌥ to type `[`/`]` at all, so
    /// `⌃⌘[`/`⌃⌘]` alone is unreachable there without a third modifier.
    public static let nextArrow = KeyboardShortcut(.rightArrow, modifiers: [.control, .command])
    public static let previousArrow = KeyboardShortcut(.leftArrow, modifiers: [.control, .command])
}
