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

            Button("Next Subagent") {
                withSelectedTask { taskId in
                    let strip = store.stripChildIDsWithLiveSurface(forTask: taskId)
                    let shown = store.subagentSwap.shownChildID(forTask: taskId)
                    if let next = SubagentSwapNavigation.next(after: shown, strip: strip) {
                        store.subagentSwap.show(childId: next, forTask: taskId)
                    } else {
                        store.subagentSwap.showMain(forTask: taskId)
                    }
                }
            }
            .keyboardShortcut(SubagentSwapShortcut.next)

            Button("Previous Subagent") {
                withSelectedTask { taskId in
                    let strip = store.stripChildIDsWithLiveSurface(forTask: taskId)
                    let shown = store.subagentSwap.shownChildID(forTask: taskId)
                    if let previous = SubagentSwapNavigation.previous(before: shown, strip: strip) {
                        store.subagentSwap.show(childId: previous, forTask: taskId)
                    } else {
                        store.subagentSwap.showMain(forTask: taskId)
                    }
                }
            }
            .keyboardShortcut(SubagentSwapShortcut.previous)
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
}
