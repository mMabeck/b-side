import SwiftUI

/// `⌃⌘0` shows the parent; `⌃⌘1`…`⌃⌘9` show the Nth child in strip order;
/// `⌃⌘]`/`⌃⌘[` step forward/back (wrapping through the parent).
///
/// `⌃⌘`-modified keys reach here even with a terminal focused, via
/// `MainMenuKeyRouter`. No `GhosttyBridge.appOwnedKeybinds` entry is needed:
/// Ghostty's default keybind table has no `ctrl+cmd+*` bindings to unbind.
public struct SubagentSwapCommands: Commands {
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandMenu("Subagents") {
            Group {
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

                // Arrow-key equivalents, hidden from the menu so "Next"/"Previous"
                // aren't listed twice, but still registered so `MainMenuKeyRouter`
                // dispatches them — `⌃⌘[`/`⌃⌘]` need ⌥ on a Danish keyboard.
                Button("Next Subagent (Arrow)") { advance(next: true) }
                    .keyboardShortcut(SubagentSwapShortcut.nextArrow)
                    .hidden()

                Button("Previous Subagent (Arrow)") { advance(next: false) }
                    .keyboardShortcut(SubagentSwapShortcut.previousArrow)
                    .hidden()
            }
            .disabled(!focus.isTaskWindowInFront)
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

/// Plain data, not introspection of a rendered `Commands` scene.
public enum SubagentSwapShortcut {
    public static let digitCount = 9

    public static let showMain = KeyboardShortcut("0", modifiers: [.control, .command])

    public static func showChild(atIndex index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
    }

    public static let next = KeyboardShortcut("]", modifiers: [.control, .command])
    public static let previous = KeyboardShortcut("[", modifiers: [.control, .command])

    /// Same actions under arrow keys: a Danish keyboard needs ⌥ to type `[`/`]` at all.
    public static let nextArrow = KeyboardShortcut(.rightArrow, modifiers: [.control, .command])
    public static let previousArrow = KeyboardShortcut(.leftArrow, modifiers: [.control, .command])
}
