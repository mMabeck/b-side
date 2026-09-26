import AppKit
import SwiftUI

/// VS Code–style "Changes" overlay: a file tree on the left, the selected
/// file's unified diff on the right, for whichever `ChangesOverlayStore.Mode`
/// is picked. Unlike `DiffSheet` (a single file, fixed content size), this is
/// a large, resizable sheet — browsing a tree needs room to work in.
struct ChangesOverlaySheet: View {
    let task: TaskRecord
    /// Shows an "Open in Editor" button for the selected file when non-nil.
    var onOpenInEditor: ((String) -> Void)?

    @State private var store = ChangesOverlayStore()
    @ObservedObject private var theme: GhosttyResolvedTheme = .shared
    @Environment(\.dismiss) private var dismiss

    private var selectionBinding: Binding<String?> {
        Binding(get: { store.selectedPath }, set: { store.select($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.palette.separator).frame(height: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(theme.palette.separator).frame(height: 1)
            footer
        }
        .frame(
            minWidth: Self.minSize.width, idealWidth: Self.idealSize.width,
            minHeight: Self.minSize.height, idealHeight: Self.idealSize.height
        )
        .background(theme.palette.windowBackground)
        .themedWindow(theme.palette)
        .resizableSheetWindow()
        .onExitCommand { dismiss() }
        .onAppear { store.present(task: task) }
        .onDisappear { store.dismiss() }
    }

    private static let minSize = CGSize(width: 900, height: 600)
    private static var idealSize: CGSize {
        guard let frame = NSScreen.main?.visibleFrame else { return CGSize(width: 1200, height: 800) }
        return CGSize(width: max(minSize.width, frame.width * 0.8), height: max(minSize.height, frame.height * 0.8))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                Picker(
                    "Mode",
                    selection: Binding(get: { store.mode }, set: { store.setMode($0) })
                ) {
                    ForEach(ChangesOverlayStore.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            HStack(spacing: 6) {
                if let branchName = store.branchName {
                    Text(branchName)
                        .font(.system(size: 11, weight: .medium))
                }
                if let baseRefLabel = store.baseRefLabel {
                    Text("vs \(Self.shortRef(baseRefLabel))")
                        .font(.system(size: 11))
                }
                Spacer()
                if !store.files.isEmpty {
                    Text("\(store.files.count) file\(store.files.count == 1 ? "" : "s"), +\(store.totalAdded) \u{2212}\(store.totalRemoved)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    /// A 7-40 character hex string reads as a commit SHA and is shortened to
    /// 7 characters for the header; anything else (a branch or tag name from
    /// a task with no recorded baseline) is shown in full.
    private static func shortRef(_ ref: String) -> String {
        guard ref.count > 7, ref.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            return ref
        }
        return String(ref.prefix(7))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .idle:
            SheetCenteredMessage(message: "Loading…", palette: theme.palette)
        case .notARepository:
            SheetCenteredMessage(message: "This task's worktree is not inside a git repository.", palette: theme.palette)
        case .error(let message):
            SheetCenteredMessage(message: "Couldn't load changes: \(message)", palette: theme.palette)
        case .loaded:
            if store.files.isEmpty {
                if store.mode != .uncommitted, store.baseRefLabel == nil {
                    noBaselineState
                } else {
                    emptyState
                }
            } else {
                HSplitView {
                    treeList
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                    diffPane
                        .frame(minWidth: 400, maxWidth: .infinity)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Changes",
            systemImage: "checkmark.circle",
            description: Text("Nothing has changed for this mode.")
        )
        .foregroundStyle(theme.palette.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
    }

    /// Shown instead of `emptyState` for `.all`/`.committed` when
    /// `TaskBaseline` couldn't resolve a baseline commit at all — an empty
    /// file list there means "couldn't compare", not "nothing changed".
    private var noBaselineState: some View {
        SheetCenteredMessage(message: "Couldn't determine this task's base commit", palette: theme.palette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.windowBackground)
    }

    // MARK: - Tree

    private var treeList: some View {
        List(selection: selectionBinding) {
            OutlineGroup(store.tree, children: \.children) { node in
                treeRow(node).tag(node.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.palette.surfaceBackground)
    }

    @ViewBuilder
    private func treeRow(_ node: ChangesTreeNode) -> some View {
        switch node {
        case .file(let file):
            fileRow(file)
        case .folder(let folder):
            folderRow(folder)
        }
    }

    private func fileRow(_ file: ChangesTreeFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
            Text(SourceControlRowView.badgeLetter(file.kind))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(SourceControlRowView.badgeColor(file.kind, palette: theme.palette))
                .frame(width: 14, alignment: .center)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            fileCounts(file)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: file))
    }

    @ViewBuilder
    private func fileCounts(_ file: ChangesTreeFile) -> some View {
        if file.isBinary {
            Text("bin")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.palette.textDisabled)
        } else {
            HStack(spacing: 4) {
                if let added = file.linesAdded, added > 0 {
                    Text("+\(added)").foregroundStyle(theme.palette.statusSuccess)
                }
                if let removed = file.linesRemoved, removed > 0 {
                    Text("\u{2212}\(removed)").foregroundStyle(theme.palette.statusError)
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    private func accessibilityLabel(for file: ChangesTreeFile) -> String {
        var parts = ["\(file.path), \(SourceControlRowView.kindDescription(file.kind).lowercased())"]
        if file.isBinary {
            parts.append("binary")
        } else {
            if let added = file.linesAdded, added > 0 {
                parts.append("\(added) addition\(added == 1 ? "" : "s")")
            }
            if let removed = file.linesRemoved, removed > 0 {
                parts.append("\(removed) deletion\(removed == 1 ? "" : "s")")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func folderRow(_ folder: ChangesTreeNode.Folder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
            Text(folder.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if folder.linesAdded > 0 {
                    Text("+\(folder.linesAdded)").foregroundStyle(theme.palette.statusSuccess)
                }
                if folder.linesRemoved > 0 {
                    Text("\u{2212}\(folder.linesRemoved)").foregroundStyle(theme.palette.statusError)
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.displayName), folder, \(folder.linesAdded) additions, \(folder.linesRemoved) deletions")
    }

    // MARK: - Diff pane

    @ViewBuilder
    private var diffPane: some View {
        if let selectedPath = store.selectedPath, let file = store.files.first(where: { $0.path == selectedPath }) {
            VStack(alignment: .leading, spacing: 0) {
                diffHeader(for: file)
                Rectangle().fill(theme.palette.separator).frame(height: 1)
                diffContent
            }
        } else {
            SheetCenteredMessage(message: "Select a file to see its diff.", palette: theme.palette)
        }
    }

    private func diffHeader(for file: ChangesTreeFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SourceControlRowView.kindDescription(file.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer()
            if let onOpenInEditor {
                ThemedSheetButton(title: "Open in Editor", palette: theme.palette) { onOpenInEditor(file.path) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.path), \(SourceControlRowView.kindDescription(file.kind))")
    }

    @ViewBuilder
    private var diffContent: some View {
        if let diffErrorMessage = store.diffErrorMessage {
            SheetCenteredMessage(message: "Couldn't load diff: \(diffErrorMessage)", palette: theme.palette)
        } else if let diffText = store.diffText {
            if diffText.isBinary {
                SheetCenteredMessage(message: "Binary file — no text diff", palette: theme.palette)
            } else if diffText.text.isEmpty {
                SheetCenteredMessage(message: "No changes", palette: theme.palette)
            } else {
                VStack(spacing: 0) {
                    if diffText.isTruncated {
                        SheetTruncationBanner(palette: theme.palette)
                    }
                    DiffTextView(
                        attributedText: UnifiedDiffRenderer.render(diffText.text, palette: theme.palette),
                        palette: theme.palette
                    )
                }
            }
        } else {
            SheetCenteredMessage(message: "Loading diff…", palette: theme.palette)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            ThemedSheetButton(title: "Done", palette: theme.palette, isPrimary: true, isDefaultAction: true) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Grants the sheet's `NSWindow` the `.resizable` style mask, which SwiftUI
/// sheets don't get by default — the tree/diff split is the whole reason
/// this sheet is large, and a fixed size defeats resizing that split's
/// panes to taste. Mirrors `ThemedWindowModifier`'s own `WindowAccessor`
/// bridging pattern (that one is private to `ThemedWindow.swift`).
private struct ResizableSheetWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.styleMask.insert(.resizable)
        }
        return view
    }

    // Mirrors `WindowAccessor` (`ThemedWindow.swift`): `makeNSView` can run
    // before the view is attached to a window, so `view.window` is nil and
    // the style mask never gets set. Retrying here on every body update
    // catches the window once it exists; the insert is a no-op once already
    // applied.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.styleMask.insert(.resizable)
        }
    }
}

extension View {
    fileprivate func resizableSheetWindow() -> some View {
        background(ResizableSheetWindowAccessor())
    }
}
