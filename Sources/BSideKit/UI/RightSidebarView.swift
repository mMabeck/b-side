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
        .background(theme.palette.surfaceBackground)
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
                    ForEach(scStore.staged) { row in
                        rowView(row, onUnstage: { Task { await scStore.unstage([row]) } })
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
                    ForEach(scStore.unstaged) { row in
                        rowView(row, onStage: { Task { await scStore.stage([row]) } })
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
                    ForEach(scStore.branchChanges) { row in
                        rowView(row)
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
        .background(theme.palette.surfaceBackground)
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
        // Discard is worktree-only (see `SourceControlStore.discard`), so it's
        // only offered on unstaged rows — there's no destructive "discard" of
        // a staged row's index entry, just Unstage.
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

    /// The rows a bulk action (discard, or a future stage/unstage-selection
    /// action) should apply to: the current multi-selection when `row` is
    /// part of it, else just `row` itself — so right-clicking or hovering a
    /// row outside the selection acts on that row alone rather than a stale
    /// selection.
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

    /// Loads and shows `row`'s diff. `requestedTaskId` is captured before the
    /// `await` so that if the selected task changes while the diff is in
    /// flight, the stale result is dropped instead of overwriting the
    /// newly-selected task's sheet — and a genuine load failure surfaces as
    /// an error rather than the empty-diff "No changes" state.
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

/// Everything `DiffSheet` needs for one presentation, resolved before the
/// sheet is shown so `DiffSheet` itself stays git-agnostic (see its own doc
/// comment).
private struct DiffSheetData: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let diffText: String
    let isBinary: Bool
    let isTruncated: Bool
    /// Set when the diff failed to load; shown instead of the diff text or
    /// the misleading "No changes" empty state.
    let errorMessage: String?
    /// `nil` for a commit shown from History — hides the DiffSheet's "Open
    /// in Editor" button, which only makes sense for a specific file.
    let row: SourceControlStore.Row?
}

private struct DiscardConfirmation: Identifiable {
    let rows: [SourceControlStore.Row]
    let title: String
    var id: String { rows.map(\.id).joined(separator: ",") }
}
