import AppKit
import OSLog
import SwiftUI

/// File tree on the left, selected file's diff on the right. Unlike `DiffSheet`
/// (fixed content size), this is a large, resizable sheet.
struct ChangesOverlaySheet: View {
    let task: TaskRecord
    /// Shows an "Open in Editor" button for the selected file when non-nil.
    var onOpenInEditor: ((String) -> Void)?

    @State private var store = ChangesOverlayStore()
    @State private var treeWidth: CGFloat = 240
    @State private var treeWidthDragStart: CGFloat?
    @State private var isHoveringDivider = false
    @State private var resizeCursorPushed = false
    @State private var vsCodePath: String?
    @ObservedObject private var theme: GhosttyResolvedTheme = .shared
    @Environment(\.dismiss) private var dismiss

    private let vsCodeDiffLauncher = VSCodeDiffLauncher()

    private static let treeWidthRange: ClosedRange<CGFloat> = 200...360

    private var selectionBinding: Binding<String?> {
        Binding(get: { store.selectedPath }, set: { store.select($0) })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                infoBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Changes")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    modePicker
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(
            minWidth: Self.minSize.width, idealWidth: Self.idealSize.width,
            minHeight: Self.minSize.height, idealHeight: Self.idealSize.height
        )
        .themedWindow(theme.palette)
        .resizableSheetWindow()
        .onExitCommand { dismiss() }
        .onAppear {
            store.present(task: task)
            vsCodePath = vsCodeDiffLauncher.resolveCodePath()
        }
        .onDisappear { store.dismiss() }
    }

    private static let minSize = CGSize(width: 1000, height: 600)
    private static var idealSize: CGSize {
        guard let frame = NSScreen.main?.visibleFrame else { return CGSize(width: 1400, height: 800) }
        return CGSize(width: max(minSize.width, frame.width * 0.92), height: max(minSize.height, frame.height * 0.8))
    }

    // MARK: - Header

    private var modePicker: some View {
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

    private var infoBar: some View {
        HStack(spacing: 8) {
            if let branchName = store.branchName {
                Text(branchName)
                    .font(.body.weight(.medium))
            }
            if let baseRefLabel = store.baseRefLabel {
                Text("vs \(Self.shortRef(baseRefLabel))")
                    .font(.body)
            }
            Spacer()
            if !store.files.isEmpty {
                Text("\(store.files.count) file\(store.files.count == 1 ? "" : "s"), +\(store.totalAdded) \u{2212}\(store.totalRemoved)")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .foregroundStyle(theme.palette.textSecondary)
        // Leading inset matches the system title's indent past the window's traffic lights.
        .padding(.leading, 80)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// A 7-40 character hex string is shortened to 7 for the header; anything else (a branch/tag name) is shown in full.
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
                HStack(spacing: 0) {
                    treeList
                        .frame(width: treeWidth)
                    treeWidthDivider
                    diffPane
                        .frame(maxWidth: .infinity)
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
    }

    /// An empty file list here means "couldn't compare", not "nothing changed".
    private var noBaselineState: some View {
        SheetCenteredMessage(message: "Couldn't determine this task's base commit", palette: theme.palette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tree

    private var treeList: some View {
        List(selection: selectionBinding) {
            OutlineGroup(store.tree, children: \.children) { node in
                treeRow(node).tag(node.id)
            }
        }
        .listStyle(.sidebar)
    }

    /// A plain `Divider()` with a drag gesture, not `HSplitView` (AppKit
    /// `updateConstraints` crash risk — see `TaskTerminalAreaView`). Global
    /// coordinate space keeps the gesture in sync with the moving divider.
    private var treeWidthDivider: some View {
        Divider()
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringDivider = hovering
                syncResizeCursor()
            }
            .onDisappear {
                isHoveringDivider = false
                treeWidthDragStart = nil
                syncResizeCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let startWidth = treeWidthDragStart ?? treeWidth
                        treeWidthDragStart = startWidth
                        treeWidth = min(max(startWidth + value.translation.width, Self.treeWidthRange.lowerBound), Self.treeWidthRange.upperBound)
                    }
                    .onEnded { _ in
                        treeWidthDragStart = nil
                        syncResizeCursor()
                    }
            )
    }

    // Hover and drag both keep the cursor; tracking our own push keeps the stack balanced.
    private func syncResizeCursor() {
        let wanted = isHoveringDivider || treeWidthDragStart != nil
        guard wanted != resizeCursorPushed else { return }
        if wanted { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        resizeCursorPushed = wanted
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
                .font(.body)
                .foregroundStyle(theme.palette.textSecondary)
            Text(SourceControlRowView.badgeLetter(file.kind))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(SourceControlRowView.badgeColor(file.kind, palette: theme.palette))
                .frame(width: 16, alignment: .center)
            Text((file.path as NSString).lastPathComponent)
                .font(.body)
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
                .font(.system(.callout, design: .monospaced))
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
            .font(.system(.callout, design: .monospaced))
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
                .font(.body)
                .foregroundStyle(theme.palette.textSecondary)
            Text(folder.displayName)
                .font(.body.weight(.medium))
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
            .font(.system(.callout, design: .monospaced))
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.headline)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SourceControlRowView.kindDescription(file.kind))
                    .font(.subheadline)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer()
            Toggle(
                "Full File",
                isOn: Binding(get: { store.showsFullFile }, set: { store.setShowsFullFile($0) })
            )
            .toggleStyle(.checkbox)
            .help("Show the entire file, not just the changed lines")
            if let vsCodePath {
                Button("Open Diff in VS Code") { openDiffInVSCode(file: file, codePath: vsCodePath) }
                    .buttonStyle(.bordered)
            }
            if let onOpenInEditor {
                Button("Open in Editor") { onOpenInEditor(file.path) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
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
            } else if let selectedPath = store.selectedPath {
                VStack(spacing: 0) {
                    if diffText.isTruncated {
                        SheetTruncationBanner(palette: theme.palette)
                    }
                    DiffPaneView(diffText: diffText.text, filePath: selectedPath, palette: theme.palette)
                }
            }
        } else {
            SheetCenteredMessage(message: "Loading diff…", palette: theme.palette)
        }
    }

    // MARK: - Open Diff in VS Code

    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "changes-overlay")

    private func openDiffInVSCode(file: ChangesTreeFile, codePath: String) {
        guard let baseRefLabel = store.baseRefLabel else { return }
        let worktreeURL = URL(fileURLWithPath: task.worktreePath)
        let fileName = (file.path as NSString).lastPathComponent
        let mode = store.mode
        Task {
            let baseContent: Data?
            if file.kind == .added || file.kind == .untracked {
                baseContent = nil
            } else {
                do {
                    baseContent = try await GitCLI.fileContent(file.origPath ?? file.path, at: baseRefLabel, in: worktreeURL)
                } catch {
                    Self.logger.error("Failed to load base content for \(file.path, privacy: .public) at \(baseRefLabel, privacy: .public): \(error, privacy: .public)")
                    return
                }
            }
            let currentContent: Data?
            switch VSCodeDiffLauncher.currentSideSource(mode: mode, kind: file.kind) {
            case .none:
                currentContent = nil
            case .worktreeFile:
                currentContent = try? Data(contentsOf: worktreeURL.appendingPathComponent(file.path))
            case .gitRef(let ref):
                currentContent = try? await GitCLI.fileContent(file.path, at: ref, in: worktreeURL)
            }
            try? vsCodeDiffLauncher.openDiff(fileName: fileName, baseContent: baseContent, currentContent: currentContent, codePath: codePath)
        }
    }
}

/// Grants `.resizable`, which SwiftUI sheets don't get by default. Mirrors `ThemedWindowModifier`'s `WindowAccessor` pattern.
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
