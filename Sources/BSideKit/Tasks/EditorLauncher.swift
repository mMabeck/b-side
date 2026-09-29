import AppKit
import Foundation

/// Prefers VS Code so a worktree opens in its own window; falls back to Insiders, Cursor, then the system default.
@MainActor
public struct EditorLauncher {
    public typealias AppResolver = (String) -> URL?

    /// Most preferred first; Cursor is a VS Code fork with the same CLI/URL scheme.
    static let editorBundleIDs = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    private let resolveApp: AppResolver
    private let workspace: NSWorkspace

    public init(resolveApp: @escaping AppResolver = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }, workspace: NSWorkspace = .shared) {
        self.resolveApp = resolveApp
        self.workspace = workspace
    }

    func resolvedEditorURL() -> URL? {
        for bundleID in Self.editorBundleIDs {
            if let url = resolveApp(bundleID) {
                return url
            }
        }
        return nil
    }

    public func openFolder(_ folder: URL) {
        guard let editorURL = resolvedEditorURL() else {
            workspace.activateFileViewerSelecting([folder])
            return
        }
        workspace.open([folder], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// Passing both URLs puts the file in its worktree's context, not a bare single-file window.
    public func openFile(_ file: URL, in folder: URL) {
        guard let editorURL = resolvedEditorURL() else {
            workspace.open(file)
            return
        }
        workspace.open([folder, file], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
