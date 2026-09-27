import Foundation
import SwiftUI
import Testing

@testable import BSideKit

/// Editor resolution order/fallback (via the injected resolver) and target-
/// folder logic — pure, no real app lookup or launch.
@MainActor
@Suite("EditorLauncher resolution")
struct EditorLauncherTests {
    @Test("Resolution prefers VS Code, then Insiders, then Cursor, in installed-candidate order; nil when none are installed", arguments: [
        Set(["com.microsoft.VSCode"]),
        Set(["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        Set(["com.microsoft.VSCodeInsiders"]),
        Set(["com.todesktop.230313mzl4w4u92"]),
        Set<String>(),
    ])
    func resolvesInPriorityOrder(installedIDs: Set<String>) {
        let urls: [String: URL] = [
            "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            "com.microsoft.VSCodeInsiders": URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app"),
            "com.todesktop.230313mzl4w4u92": URL(fileURLWithPath: "/Applications/Cursor.app"),
        ]
        let launcher = EditorLauncher(resolveApp: { id in installedIDs.contains(id) ? urls[id] : nil })

        let priorityOrder = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
        let expected = priorityOrder.first { installedIDs.contains($0) }.flatMap { urls[$0] }
        #expect(launcher.resolvedEditorURL() == expected)
    }
}

/// Which folder "Open in VS Code" opens, given the current `MainSelection` —
/// pure, no store or database needed. Mirrors
/// `ProjectCommandsDefaultTargetTests`'s pattern.
@Suite("EditorCommands target folder")
struct EditorCommandsTargetFolderTests {
    private static let project = Project(id: 1, path: "/tmp/project-a", displayName: "a")
    private static let task = TaskRecord(
        id: 10, projectId: 1, name: "T", branchName: "b",
        worktreePath: "/tmp/project-a-worktrees/t", harness: "claude", permissionLevel: "default"
    )

    @Test("opens the selected task's worktree, not its project's own path")
    func prefersTaskWorktree() {
        let result = EditorCommands.targetFolder(selection: .task(Self.task, Self.project))
        #expect(result == URL(fileURLWithPath: "/tmp/project-a-worktrees/t"))
    }

    @Test("falls back to the selected project's path when no task is selected")
    func fallsBackToProjectPath() {
        let result = EditorCommands.targetFolder(selection: .project(Self.project))
        #expect(result == URL(fileURLWithPath: "/tmp/project-a"))
    }

    @Test("resolves to nil, so both triggers can disable themselves, when nothing is selected")
    func nilWhenNothingSelected() {
        let result = EditorCommands.targetFolder(selection: .none)
        #expect(result == nil)
    }
}

/// The "Open in VS Code" key equivalent, as plain data — same rationale as
/// `WindowLayoutTests`.
@Suite("Editor shortcut")
struct EditorShortcutTests {
    @Test("doesn't collide with the other app shortcuts")
    func noCollisionWithOtherShortcuts() {
        let others: [(Character, EventModifiers)] = [
            (WindowLayoutShortcut.leftSidebar.key.character, WindowLayoutShortcut.leftSidebar.modifiers),
            (WindowLayoutShortcut.rightSidebar.key.character, WindowLayoutShortcut.rightSidebar.modifiers),
            (WindowLayoutShortcut.terminalDrawer.key.character, WindowLayoutShortcut.terminalDrawer.modifiers),
            (TerminalCloseShortcut.closeTask.key.character, TerminalCloseShortcut.closeTask.modifiers),
            (TerminalCloseShortcut.restartSession.key.character, TerminalCloseShortcut.restartSession.modifiers),
        ]
        for (character, modifiers) in others {
            let same = character == EditorShortcut.openInEditor.key.character && modifiers == EditorShortcut.openInEditor.modifiers
            #expect(!same)
        }
    }
}
