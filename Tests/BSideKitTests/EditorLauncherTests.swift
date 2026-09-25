import Foundation
import SwiftUI
import Testing

@testable import BSideKit

/// Editor resolution order/fallback (via the injected resolver) and target-
/// folder logic — pure, no real app lookup or launch.
@MainActor
@Suite("EditorLauncher resolution")
struct EditorLauncherTests {
    @Test("resolves VS Code when it's the only installed candidate")
    func resolvesVSCode() {
        let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let launcher = EditorLauncher(resolveApp: { id in id == "com.microsoft.VSCode" ? vscode : nil })
        #expect(launcher.resolvedEditorURL() == vscode)
    }

    @Test("prefers VS Code over Insiders and Cursor when multiple are installed")
    func prefersVSCodeOverAlternatives() {
        let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let insiders = URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")
        let launcher = EditorLauncher(resolveApp: { id in
            switch id {
            case "com.microsoft.VSCode": return vscode
            case "com.microsoft.VSCodeInsiders": return insiders
            default: return nil
            }
        })
        #expect(launcher.resolvedEditorURL() == vscode)
    }

    @Test("falls back to Insiders when VS Code proper isn't installed")
    func fallsBackToInsiders() {
        let insiders = URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")
        let launcher = EditorLauncher(resolveApp: { id in id == "com.microsoft.VSCodeInsiders" ? insiders : nil })
        #expect(launcher.resolvedEditorURL() == insiders)
    }

    @Test("falls back to Cursor when neither VS Code nor Insiders is installed")
    func fallsBackToCursor() {
        let cursor = URL(fileURLWithPath: "/Applications/Cursor.app")
        let launcher = EditorLauncher(resolveApp: { id in id == "com.todesktop.230313mzl4w4u92" ? cursor : nil })
        #expect(launcher.resolvedEditorURL() == cursor)
    }

    @Test("resolves to nil, so callers fall back to Finder/the default app, when no candidate is installed")
    func nilWhenNoneInstalled() {
        let launcher = EditorLauncher(resolveApp: { _ in nil })
        #expect(launcher.resolvedEditorURL() == nil)
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
    @Test("Open in VS Code shortcut is Shift+Cmd+O")
    func openInEditorShortcut() {
        #expect(EditorShortcut.openInEditor.key.character == "o")
        #expect(EditorShortcut.openInEditor.modifiers == [.command, .shift])
    }

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
