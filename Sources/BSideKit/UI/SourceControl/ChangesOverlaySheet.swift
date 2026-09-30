import AppKit
import OSLog
import SwiftUI

struct ChangesOverlaySheet: View {
    let task: TaskRecord
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
        Binding(get: { store.focusedRowID }, set: { store.focusRow($0) })
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
        .closesSheetOnCommandW { dismiss() }
        .onAppear {
            store.present(task: task)
            vsCodePath = vsCodeDiffLauncher.resolveCodePath()
        }
        .onDisappear { store.dismiss() }
        .background(navigationShortcuts)
    }

    // Hidden buttons keep the shortcuts live whether focus is in the tree or the diff text view.
    private var navigationShortcuts: some View {
        let f7 = KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!))
        return Group {
            Button("Next Change") { store.goToNextChange() }
                .keyboardShortcut(f7, modifiers: [])
            Button("Previous Change") { store.goToPreviousChange() }
                .keyboardShortcut(f7, modifiers: .shift)
            Button("Next Change") { store.goToNextChange() }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous Change") { store.goToPreviousChange() }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next File") { store.selectNextFile() }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Button("Previous File") { store.selectPreviousFile() }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
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
                    .font(.callout.weight(.medium))
            }
            if let baseRefLabel = store.baseRefLabel {
                Text("vs \(Self.shortRef(baseRefLabel))")
                    .font(.callout)
            }
            Spacer()
            if !store.files.isEmpty {
                Text("\(store.files.count) file\(store.files.count == 1 ? "" : "s"), +\(store.totalAdded) \u{2212}\(store.totalRemoved)")
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .foregroundStyle(theme.palette.textSecondary)
        // Leading inset matches the system title's indent past the window's traffic lights.
        .padding(.leading, 80)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

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

    private var noBaselineState: some View {
        SheetCenteredMessage(message: "Couldn't determine this task's base commit", palette: theme.palette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tree

    private var treeList: some View {
        VStack(spacing: 0) {
            treeHeader
            ScrollViewReader { proxy in
                List(selection: selectionBinding) {
                    ForEach(store.visibleRows) { row in
                        treeRow(row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8 + CGFloat(row.depth) * 12, bottom: 0, trailing: 10))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, ChangesRowStyle.rowHeight)
                .scrollContentBackground(.hidden)
                .onKeyPress(.leftArrow) { handleTreeKey { store.collapseFocusedOrMoveToParent() } }
                .onKeyPress(.rightArrow) { handleTreeKey { store.expandFocusedOrMoveToFirstChild() } }
                .onKeyPress(.space) { handleTreeKey(foldersOnly: true) { store.toggleFocusedFolder() } }
                .onKeyPress(.return) { handleTreeKey(foldersOnly: true) { store.toggleFocusedFolder() } }
                .onChange(of: store.focusedRowID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .background(theme.palette.surfaceBackground)
    }

    @ViewBuilder
    private func treeRow(_ row: ChangesTreeRow) -> some View {
        switch row.node {
        case .file(let file):
            ChangesFileRow(file: file, palette: theme.palette)
                .tag(file.id)
        case .folder(let folder):
            ChangesFolderRow(
                folder: folder,
                isExpanded: !store.collapsedFolderIDs.contains(folder.id),
                palette: theme.palette
            ) {
                store.focusRow(folder.id)
                store.toggleFolder(folder.id)
            }
            .tag(folder.id)
        }
    }

    private func handleTreeKey(foldersOnly: Bool = false, _ action: () -> Void) -> KeyPress.Result {
        guard let id = store.focusedRowID else { return .ignored }
        let isFile = store.files.contains { $0.path == id }
        if isFile && foldersOnly { return .ignored }
        action()
        return .handled
    }

    private var treeHeader: some View {
        HStack(spacing: 6) {
            Text("CHANGES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
            Text("\(store.files.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.palette.separator))
                .accessibilityLabel("\(store.files.count) changed files")
            Spacer()
            iconButton("Expand All", systemImage: "arrow.up.left.and.arrow.down.right") { store.expandAllFolders() }
            iconButton("Collapse All", systemImage: "arrow.down.right.and.arrow.up.left") { store.collapseAllFolders() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.palette.separator).frame(height: 1) }
    }

    private func iconButton(
        _ title: String, systemImage: String, accessibilityLabel: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.palette.textSecondary)
        .help(title)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    /// Plain `Divider()` with a drag gesture, not `HSplitView` (`updateConstraints` crash); global coordinates keep the drag in sync.
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
        let directory = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Text((file.path as NSString).lastPathComponent)
                .font(.callout.weight(.semibold))
                .strikethrough(file.kind == .deleted)
                .foregroundStyle(ChangesRowStyle.statusColor(file.kind, palette: theme.palette))
                .lineLimit(1)
            if !directory.isEmpty {
                Text(directory)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(SourceControlRowView.kindDescription(file.kind))
                .font(.caption2)
                .foregroundStyle(theme.palette.textDisabled)
                .layoutPriority(1)
            Spacer(minLength: 8)
            changeNavigationControls
            Toggle(isOn: Binding(get: { store.showsFullFile }, set: { store.setShowsFullFile($0) })) {
                Label("Full File", systemImage: "doc.plaintext")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show the entire file, not just the changed lines")
            if let vsCodePath {
                iconButton("Open Diff in VS Code", systemImage: "rectangle.split.2x1") {
                    openDiffInVSCode(file: file, codePath: vsCodePath)
                }
            }
            if let onOpenInEditor {
                iconButton("Open in Editor", systemImage: "square.and.pencil") { onOpenInEditor(file.path) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(theme.palette.surfaceBackground)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var changeNavigationControls: some View {
        if store.changeCount > 0 {
            Text(changeCounterText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityLabel(changeCounterText)
            iconButton("Previous Change (\u{21E7}F7, \u{2325}\u{2191})", systemImage: "chevron.up", accessibilityLabel: "Previous Change") {
                store.goToPreviousChange()
            }
            iconButton("Next Change (F7, \u{2325}\u{2193})", systemImage: "chevron.down", accessibilityLabel: "Next Change") {
                store.goToNextChange()
            }
        }
    }

    private var changeCounterText: String {
        let count = store.changeCount
        guard let index = store.currentChangeIndex else { return "\(count) change\(count == 1 ? "" : "s")" }
        return "\(index + 1) of \(count)"
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
                    DiffPaneView(
                        diffText: diffText.text, rows: store.diffRows, filePath: selectedPath, palette: theme.palette,
                        focusedBlock: store.currentChangeBlock
                    )
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

extension View {
    /// Grants `.resizable`, which SwiftUI sheets don't get by default.
    fileprivate func resizableSheetWindow() -> some View {
        background(WindowAccessor { window in
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        })
    }
}
