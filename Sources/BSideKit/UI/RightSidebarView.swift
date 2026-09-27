import AppKit
import SwiftUI

/// Right sidebar: Source Control (subagent activity lives in each task's
/// `SubagentStripView`). Modelled on VS Code's SCM view, scoped to the
/// selected task's worktree — see native-rewrite.md §7.
struct RightSidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var scStore = SourceControlStore()
    @State private var selection: Set<String> = []
    @State private var diffSheetData: DiffSheetData?
    @State private var discardConfirmation: DiscardConfirmation?
    @State private var historyExpanded = false
    @FocusState private var commitFieldFocused: Bool

    private let editorLauncher = EditorLauncher()

    var body: some View {
        VStack(spacing: 0) {
            if scStore.task != nil {
                header
                Rectangle().fill(theme.palette.separator).frame(height: 1)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if scStore.task != nil {
                if scStore.hasRemote {
                    Rectangle().fill(theme.palette.separator).frame(height: 1)
                    PushAreaView(
                        aheadCount: scStore.aheadBehind?.ahead,
                        isPushing: scStore.isPushing,
                        canPush: !scStore.isPushing && !scStore.isCommitting,
                        log: scStore.pushLog,
                        palette: theme.palette,
                        onPush: { scStore.push() },
                        onCancel: { scStore.cancelPush() }
                    )
                }
                Rectangle().fill(theme.palette.separator).frame(height: 1)
                CommitAreaView(
                    message: $scStore.commitMessage,
                    isCommitting: scStore.isCommitting,
                    log: scStore.commitLog,
                    canCommit: !scStore.isCommitting && !scStore.isPushing && !scStore.staged.isEmpty
                        && !scStore.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    palette: theme.palette,
                    isFocused: $commitFieldFocused,
                    onCommit: { scStore.commit() },
                    onCancel: { scStore.cancelCommit() }
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: store.selectedTask) {
            scStore.setTask(store.selectedTask)
        }
        .sheet(item: $diffSheetData) { data in
            DiffSheet(
                title: data.title,
                subtitle: data.subtitle,
                diffText: data.diffText,
                isBinary: data.isBinary,
                isTruncated: data.isTruncated,
                errorMessage: data.errorMessage,
                onOpenInEditor: data.row.map { row in { openInEditor(row) } }
            )
        }
        .confirmationDialog(
            discardConfirmation?.title ?? "",
            isPresented: Binding(
                get: { discardConfirmation != nil },
                set: { if !$0 { discardConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let discardConfirmation {
                Button("Discard Changes", role: .destructive) {
                    let rows = discardConfirmation.rows
                    self.discardConfirmation = nil
                    Task { await scStore.discard(rows) }
                }
                Button("Cancel", role: .cancel) { self.discardConfirmation = nil }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Source Control")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            Button("Show All Changes") {
                store.pendingChangesOverlayTask = scStore.task
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.palette.accent)
            .help("Show All Changes (\u{2318}\u{21e7}D)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if scStore.task == nil {
            emptyState(
                title: "No Task Selected",
                systemImage: "arrow.triangle.branch",
                description: "Select a task to see its changed files, staging and commit."
            )
        } else {
            switch scStore.loadState {
            case .idle:
                emptyState(
                    title: "Source Control",
                    systemImage: "arrow.triangle.branch",
                    description: "Loading…"
                )
            case .notARepository:
                emptyState(
                    title: "Not a Git Repository",
                    systemImage: "exclamationmark.triangle",
                    description: "This task's worktree is not inside a git repository."
                )
            case .error(let message):
                emptyState(
                    title: "Couldn't Load Source Control",
                    systemImage: "exclamationmark.triangle",
                    description: message
                )
            case .loaded:
                if scStore.staged.isEmpty && scStore.unstaged.isEmpty && scStore.branchChanges.isEmpty {
                    emptyState(
                        title: "No Changes",
                        systemImage: "checkmark.circle",
                        description: "The working tree is clean and nothing has been committed on this branch yet."
                    )
                } else {
                    fileList
                }
            }
        }
    }

    private func emptyState(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(selection: $selection) {
            if !scStore.staged.isEmpty {
                Section {
                    ForEach(ChangesTreeBuilder.build(scStore.staged)) { node in
                        SourceControlTreeRow(
                            node: node,
                            palette: theme.palette,
                            onUnstageFolder: { rows in Task { await scStore.unstage(rows) } },
                            rowContent: { row in rowView(row, onUnstage: { Task { await scStore.unstage([row]) } }) }
                        )
                    }
                } header: {
                    sectionHeader(
                        "Staged Changes",
                        actionTitle: "Unstage All",
                        action: { Task { await scStore.unstageAll() } }
                    )
                }
            }

            if !scStore.unstaged.isEmpty {
                Section {
                    ForEach(ChangesTreeBuilder.build(scStore.unstaged)) { node in
                        SourceControlTreeRow(
                            node: node,
                            palette: theme.palette,
                            onStageFolder: { rows in Task { await scStore.stage(rows) } },
                            rowContent: { row in rowView(row, onStage: { Task { await scStore.stage([row]) } }) }
                        )
                    }
                } header: {
                    sectionHeader(
                        "Changes",
                        actionTitle: "Stage All",
                        action: { Task { await scStore.stageAll() } }
                    )
                }
            }

            if !scStore.branchChanges.isEmpty {
                Section("Committed on this branch") {
                    ForEach(ChangesTreeBuilder.build(scStore.branchChanges)) { node in
                        SourceControlTreeRow(node: node, palette: theme.palette, rowContent: { row in rowView(row) })
                    }
                }
            }

            if !scStore.history.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        ForEach(scStore.history) { commit in
                            historyRowView(commit)
                        }
                    } label: {
                        Text("History")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.palette.accent)
        }
    }

    private func rowView(
        _ row: SourceControlStore.Row,
        onStage: (() -> Void)? = nil,
        onUnstage: (() -> Void)? = nil
    ) -> some View {
        // Discard is worktree-only, so only offered on unstaged rows; a staged row's index entry gets Unstage instead.
        let onDiscard: (() -> Void)? = row.origin == .unstaged ? {
            requestDiscard(for: selectedRowsOrThis(row))
        } : nil

        return SourceControlRowView(row: row, palette: theme.palette, onStage: onStage, onUnstage: onUnstage, onDiscard: onDiscard)
            .tag(row.id)
            .contentShape(Rectangle())
            .onTapGesture { openDiff(for: row) }
            .contextMenu {
                contextMenu(for: row)
            }
    }

    /// The multi-selection if `row` is part of it, else just `row` — so a
    /// right-click outside the selection acts on that row alone.
    private func selectedRowsOrThis(_ row: SourceControlStore.Row) -> [SourceControlStore.Row] {
        guard selection.contains(row.id) else { return [row] }
        let all = scStore.staged + scStore.unstaged + scStore.branchChanges
        return all.filter { selection.contains($0.id) }
    }

    private func requestDiscard(for rows: [SourceControlStore.Row]) {
        let names = rows.map(\.displayName).joined(separator: ", ")
        discardConfirmation = DiscardConfirmation(
            rows: rows,
            title: rows.count == 1 ? "Discard changes to \(names)?" : "Discard changes to \(rows.count) files?"
        )
    }

    @ViewBuilder
    private func contextMenu(for row: SourceControlStore.Row) -> some View {
        let rows = selectedRowsOrThis(row)

        if row.origin == .unstaged {
            Button("Stage") { Task { await scStore.stage(rows) } }
        }
        if row.origin == .staged {
            Button("Unstage") { Task { await scStore.unstage(rows) } }
        }
        if row.origin == .unstaged {
            Button("Discard…", role: .destructive) { requestDiscard(for: rows) }
            if row.kind == .untracked {
                Button("Add to .gitignore") { Task { await scStore.addToGitignore(row) } }
            }
        }
        Divider()
        Button("Open in Editor") { openInEditor(row) }
        Button("Reveal in Finder") { revealInFinder(row) }
    }

    // MARK: - History

    private func historyRowView(_ commit: GitCLI.CommitSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(commit.subject)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(commit.shortSha) \u{2022} \(commit.author)")
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.textDisabled)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { openCommitDiff(commit) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Commit \(commit.shortSha), \(commit.subject), by \(commit.author)")
    }

    private func openCommitDiff(_ commit: GitCLI.CommitSummary) {
        let requestedTaskId = scStore.task?.id
        Task {
            do {
                let diff = try await scStore.diffText(forCommit: commit.sha)
                guard scStore.task?.id == requestedTaskId else { return }
                diffSheetData = DiffSheetData(
                    id: "commit:\(commit.sha)",
                    title: commit.subject,
                    subtitle: "\(commit.shortSha) \u{2022} \(commit.author)",
                    diffText: diff.text,
                    isBinary: diff.isBinary,
                    isTruncated: diff.isTruncated,
                    errorMessage: nil,
                    row: nil
                )
            } catch {
                guard scStore.task?.id == requestedTaskId else { return }
                diffSheetData = DiffSheetData(
                    id: "commit:\(commit.sha)",
                    title: commit.subject,
                    subtitle: "\(commit.shortSha) \u{2022} \(commit.author)",
                    diffText: "",
                    isBinary: false,
                    isTruncated: false,
                    errorMessage: Self.describe(error),
                    row: nil
                )
            }
        }
    }

    // MARK: - Diff sheet

    /// `requestedTaskId` is captured before the `await` so a stale result
    /// from a since-changed selection is dropped instead of overwriting the new task's sheet.
    private func openDiff(for row: SourceControlStore.Row) {
        let requestedTaskId = scStore.task?.id
        Task {
            do {
                let diff = try await scStore.diffText(for: row)
                guard scStore.task?.id == requestedTaskId else { return }
                diffSheetData = DiffSheetData(
                    id: row.id,
                    title: row.displayName,
                    subtitle: subtitle(for: row),
                    diffText: diff.text,
                    isBinary: diff.isBinary,
                    isTruncated: diff.isTruncated,
                    errorMessage: nil,
                    row: row
                )
            } catch {
                guard scStore.task?.id == requestedTaskId else { return }
                diffSheetData = DiffSheetData(
                    id: row.id,
                    title: row.displayName,
                    subtitle: subtitle(for: row),
                    diffText: "",
                    isBinary: false,
                    isTruncated: false,
                    errorMessage: Self.describe(error),
                    row: row
                )
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GitCLI.CommandError {
            return error.description
        }
        return String(describing: error)
    }

    private func subtitle(for row: SourceControlStore.Row) -> String {
        switch row.origin {
        case .staged: return "Staged"
        case .unstaged: return row.kind == .untracked ? "Untracked" : "Unstaged"
        case .branch: return "Committed on branch"
        }
    }

    // MARK: - Editor / Finder

    private func openInEditor(_ row: SourceControlStore.Row) {
        guard let folder = EditorCommands.targetFolder(selection: store.mainSelection) else { return }
        editorLauncher.openFile(folder.appendingPathComponent(row.path), in: folder)
    }

    private func revealInFinder(_ row: SourceControlStore.Row) {
        guard let folder = EditorCommands.targetFolder(selection: store.mainSelection) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(row.path)])
    }
}

/// Everything `DiffSheet` needs, resolved before the sheet is shown so `DiffSheet` itself stays git-agnostic.
private struct DiffSheetData: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let diffText: String
    let isBinary: Bool
    let isTruncated: Bool
    /// Shown instead of the diff text or misleading "No changes" state.
    let errorMessage: String?
    /// `nil` for a commit from History — hides "Open in Editor", which only makes sense for a specific file.
    let row: SourceControlStore.Row?
}

private struct DiscardConfirmation: Identifiable {
    let rows: [SourceControlStore.Row]
    let title: String
    var id: String { rows.map(\.id).joined(separator: ",") }
}

/// Renders a `ChangesTreeRowNode`: folders as expanded-by-default `DisclosureGroup`s
/// with combined +/− counts (and, if given, whole-folder stage/unstage on hover), files via `rowContent`.
private struct SourceControlTreeRow<RowContent: View>: View {
    let node: ChangesTreeRowNode
    let palette: BSidePalette
    var onStageFolder: (([SourceControlStore.Row]) -> Void)?
    var onUnstageFolder: (([SourceControlStore.Row]) -> Void)?
    @ViewBuilder var rowContent: (SourceControlStore.Row) -> RowContent

    @State private var isExpanded = true
    @State private var isHovering = false

    var body: some View {
        switch node {
        case .file(let row):
            rowContent(row)
        case .folder(let folder):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(folder.children) { child in
                    SourceControlTreeRow(
                        node: child,
                        palette: palette,
                        onStageFolder: onStageFolder,
                        onUnstageFolder: onUnstageFolder,
                        rowContent: rowContent
                    )
                }
            } label: {
                folderLabel(folder)
            }
        }
    }

    private func folderLabel(_ folder: ChangesTreeRowNode.Folder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
            Text(folder.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isHovering, onStageFolder != nil || onUnstageFolder != nil {
                folderHoverButtons(folder)
            } else {
                folderCounts(folder)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.displayName), folder, \(folder.linesAdded) additions, \(folder.linesRemoved) deletions")
    }

    private func folderCounts(_ folder: ChangesTreeRowNode.Folder) -> some View {
        HStack(spacing: 4) {
            if folder.linesAdded > 0 {
                Text("+\(folder.linesAdded)").foregroundStyle(palette.statusSuccess)
            }
            if folder.linesRemoved > 0 {
                Text("\u{2212}\(folder.linesRemoved)").foregroundStyle(palette.statusError)
            }
        }
        .font(.system(size: 9, design: .monospaced))
    }

    private func folderHoverButtons(_ folder: ChangesTreeRowNode.Folder) -> some View {
        HStack(spacing: 4) {
            if let onStageFolder {
                folderIconButton("plus", label: "Stage \(folder.displayName)") { onStageFolder(node.leaves) }
            }
            if let onUnstageFolder {
                folderIconButton("minus", label: "Unstage \(folder.displayName)") { onUnstageFolder(node.leaves) }
            }
        }
    }

    private func folderIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary)
        .accessibilityLabel(label)
    }
}
