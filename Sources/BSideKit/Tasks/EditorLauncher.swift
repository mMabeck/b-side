import AppKit
import Foundation

/// Opens a folder (optionally with one file inside it) in an installed code
/// editor, for "Open in IDE"/"Open in Editor" actions. Prefers VS Code, so a
/// worktree opens as its own editor window rather than reusing whatever
/// window last had focus, which `open -a`/the `code` CLI cannot guarantee
/// and which this app cannot depend on being on `PATH` at all.
///
/// App lookup goes through an injected resolver rather than calling
/// `NSWorkspace` APIs directly, so tests can assert the bundle-id fallback
/// order (VS Code → Insiders → Cursor → system default) without any editor
/// actually being installed on the test machine.
@MainActor
public struct EditorLauncher {
    /// Given a bundle identifier, returns the URL of an installed app with
    /// that identifier, or `nil` if none is installed. Matches the shape of
    /// `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
    public typealias AppResolver = (String) -> URL?

    /// Candidate code editors, most preferred first. VS Code proper, then
    /// Insiders, then Cursor (a VS Code fork with an identical CLI/URL
    /// scheme) — all three open a folder-plus-file the same way, so the
    /// first one found is used.
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

    /// The first installed candidate editor's app URL, in preference order,
    /// or `nil` if none of `editorBundleIDs` is installed.
    func resolvedEditorURL() -> URL? {
        for bundleID in Self.editorBundleIDs {
            if let url = resolveApp(bundleID) {
                return url
            }
        }
        return nil
    }

    /// Opens `folder` in the resolved editor, or in Finder if no candidate
    /// editor is installed.
    public func openFolder(_ folder: URL) {
        guard let editorURL = resolvedEditorURL() else {
            workspace.activateFileViewerSelecting([folder])
            return
        }
        workspace.open([folder], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// Opens `file` inside an editor window scoped to `folder` — passing
    /// both URLs to the editor, rather than opening `file` alone, is what
    /// puts the file in the context of its worktree instead of a bare
    /// single-file window. Falls back to the system's default app for
    /// `file` if no candidate editor is installed.
    public func openFile(_ file: URL, in folder: URL) {
        guard let editorURL = resolvedEditorURL() else {
            workspace.open(file)
            return
        }
        workspace.open([folder, file], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
