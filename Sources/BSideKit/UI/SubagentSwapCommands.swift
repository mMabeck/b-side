import SwiftUI

/// Ctrl-Cmd keys reach here via `MainMenuKeyRouter` even with a terminal focused; Ghostty has no `ctrl+cmd+*` defaults to unbind.
public struct SubagentSwapCommands: Commands {
    private var store: ProjectsStore
    @FocusedValue(\.projectsStore) private var focusedStore

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

                // Arrow equivalents are hidden from the menu but registered for `MainMenuKeyRouter`; ⌃⌘[/] need ⌥ on a Danish keyboard.
                Button("Next Subagent (Arrow)") { advance(next: true) }
                    .keyboardShortcut(SubagentSwapShortcut.nextArrow)
                    .hidden()

                Button("Previous Subagent (Arrow)") { advance(next: false) }
                    .keyboardShortcut(SubagentSwapShortcut.previousArrow)
                    .hidden()
            }
            .disabled(focusedStore == nil)
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

public enum SubagentSwapShortcut {
    public static let digitCount = 9

    public static let showMain = KeyboardShortcut("0", modifiers: [.control, .command])

    public static func showChild(atIndex index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
    }

    public static let next = KeyboardShortcut("]", modifiers: [.control, .command])
    public static let previous = KeyboardShortcut("[", modifiers: [.control, .command])

    public static let nextArrow = KeyboardShortcut(.rightArrow, modifiers: [.control, .command])
    public static let previousArrow = KeyboardShortcut(.leftArrow, modifiers: [.control, .command])
}
