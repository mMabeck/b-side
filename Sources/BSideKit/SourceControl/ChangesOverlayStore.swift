import Foundation
import Observation

/// Separate from `SourceControlStore`: the overlay opens rarely and its modes are wasted work on every sidebar refresh.
@MainActor
@Observable
public final class ChangesOverlayStore {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case all
        case committed
        case uncommitted

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .all: return "All"
            case .committed: return "Committed"
            case .uncommitted: return "Uncommitted"
            }
        }
    }

    public enum LoadState: Equatable, Sendable {
        case idle
        case loaded
        case notARepository
        case error(String)
    }

    public private(set) var mode: Mode = .all
    public private(set) var loadState: LoadState = .idle
    public private(set) var files: [ChangesTreeFile] = []
    public private(set) var tree: [ChangesTreeNode] = []
    public private(set) var selectedPath: String?
    /// The highlighted tree row: a file (always equal to `selectedPath`) or a folder, whose selection leaves the last file's diff in place.
    public private(set) var focusedRowID: String?
    public private(set) var diffText: GitCLI.DiffText?
    private(set) var diffRows: [UnifiedDiffRenderer.Row] = []
    public private(set) var diffErrorMessage: String?
    public private(set) var branchName: String?
    /// The task's baseline for `.all`/`.committed`, `"HEAD"` for `.uncommitted`.
    public private(set) var baseRefLabel: String?
    public private(set) var showsFullFile = false
    /// Tracks collapsed rather than expanded folders so new folders appear expanded.
    public private(set) var collapsedFolderIDs: Set<String> = []

    private(set) var changeBlocks: [DiffChangeBlock] = []
    public private(set) var currentChangeIndex: Int?
    public var changeCount: Int { changeBlocks.count }
    var currentChangeBlock: DiffChangeBlock? { currentChangeIndex.map { changeBlocks[$0] } }

    public var totalAdded: Int { files.reduce(0) { $0 + ($1.linesAdded ?? 0) } }
    public var totalRemoved: Int { files.reduce(0) { $0 + ($1.linesRemoved ?? 0) } }

    private var task: TaskRecord?
    private var worktreeURL: URL? { task.map { URL(fileURLWithPath: $0.worktreePath) } }
    private var watcher: WorktreeWatcher?
    private var refreshGeneration = 0
    private var diffLoadGeneration = 0
    private var pendingLanding: ChangeNavigation.Direction?

    public init() {}

    public func present(task: TaskRecord) {
        self.task = task
        mode = .all
        selectedPath = nil
        focusedRowID = nil
        diffText = nil
        diffErrorMessage = nil
        resetChangeNavigation()
        loadState = .idle
        files = []
        tree = []
        collapsedFolderIDs = []
        branchName = nil
        baseRefLabel = nil

        let url = URL(fileURLWithPath: task.worktreePath)
        let watcher = WorktreeWatcher(worktreeURL: url) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        self.watcher = watcher
        watcher.start()
        Task { await refresh() }
    }

    /// Call on dismiss so it doesn't keep refreshing (and spawning git processes) in the background.
    public func dismiss() {
        watcher?.stop()
        watcher = nil
        task = nil
    }

    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        resetChangeNavigation()
        Task { await refresh() }
    }

    public func setShowsFullFile(_ newValue: Bool) {
        guard newValue != showsFullFile else { return }
        showsFullFile = newValue
        resetChangeNavigation()
        Task { await loadDiff() }
    }

    public var visibleRows: [ChangesTreeRow] {
        ChangesTreeRow.visibleRows(tree, collapsed: collapsedFolderIDs)
    }

    public func toggleFolder(_ id: String) {
        if collapsedFolderIDs.remove(id) == nil { collapsedFolderIDs.insert(id) }
    }

    public func focusRow(_ id: String?) {
        guard let id else { return }
        focusedRowID = id
        if files.contains(where: { $0.path == id }) { select(id) }
    }

    public func toggleFocusedFolder() {
        if let folder = focusedFolder { toggleFolder(folder.id) }
    }

    /// Collapses an expanded folder; otherwise moves focus to the parent folder.
    public func collapseFocusedOrMoveToParent() {
        guard let focusedRowID, let ancestors = Self.ancestors(of: focusedRowID, in: tree) else { return }
        if let folder = focusedFolder, !collapsedFolderIDs.contains(folder.id) {
            collapsedFolderIDs.insert(folder.id)
        } else if let parent = ancestors.last {
            self.focusedRowID = parent.id
        }
    }

    /// Expands a collapsed folder; on an expanded one moves focus to its first child.
    public func expandFocusedOrMoveToFirstChild() {
        guard let folder = focusedFolder else { return }
        if collapsedFolderIDs.contains(folder.id) {
            collapsedFolderIDs.remove(folder.id)
        } else if let first = folder.children.first {
            focusRow(first.id)
        }
    }

    private var focusedFolder: ChangesTreeNode.Folder? {
        guard let focusedRowID, let ancestors = Self.ancestors(of: focusedRowID, in: tree) else { return nil }
        for node in (ancestors.last?.children ?? tree) where node.id == focusedRowID {
            if case .folder(let folder) = node { return folder }
        }
        return nil
    }

    private static func ancestors(of id: String, in nodes: [ChangesTreeNode]) -> [ChangesTreeNode.Folder]? {
        for node in nodes {
            if node.id == id { return [] }
            if case .folder(let folder) = node, let inner = ancestors(of: id, in: folder.children) { return [folder] + inner }
        }
        return nil
    }

    public func expandAllFolders() {
        collapsedFolderIDs = []
    }

    public func collapseAllFolders() {
        collapsedFolderIDs = Set(Self.folderIDs(in: tree))
    }

    private static func folderIDs(in nodes: [ChangesTreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            guard case .folder(let folder) = node else { return [] }
            return [folder.id] + folderIDs(in: folder.children)
        }
    }

    public func select(_ path: String?) {
        guard path != selectedPath else { return }
        if let path, !files.contains(where: { $0.path == path }) { return }
        selectedPath = path
        focusedRowID = path
        resetChangeNavigation()
        Task { await loadDiff() }
    }

    public func goToNextChange() { stepChange(.forward) }
    public func goToPreviousChange() { stepChange(.backward) }
    public func selectNextFile() { selectAdjacentFile(.forward) }
    public func selectPreviousFile() { selectAdjacentFile(.backward) }

    private func stepChange(_ direction: ChangeNavigation.Direction) {
        switch ChangeNavigation.step(from: currentChangeIndex, count: changeBlocks.count, direction: direction) {
        case .block(let index): currentChangeIndex = index
        case .adjacentFile: selectAdjacentFile(direction, landingOnChange: true)
        }
    }

    private func selectAdjacentFile(_ direction: ChangeNavigation.Direction, landingOnChange: Bool = false) {
        let paths = tree.flatMap(\.leaves).map(\.path)
        let target: String?
        if let selectedPath, let index = paths.firstIndex(of: selectedPath) {
            let neighbour = direction == .forward ? index + 1 : index - 1
            target = paths.indices.contains(neighbour) ? paths[neighbour] : nil
        } else {
            target = direction == .forward ? paths.first : paths.last
        }
        guard let target else {
            pendingLanding = nil
            return
        }
        for folder in Self.ancestors(of: target, in: tree) ?? [] { collapsedFolderIDs.remove(folder.id) }
        focusRow(target)
        if landingOnChange { pendingLanding = direction }
    }

    private func resetChangeNavigation() {
        changeBlocks = []
        currentChangeIndex = nil
        pendingLanding = nil
    }

    private func updateChangeBlocks() {
        changeBlocks = DiffChangeBlock.blocks(in: diffRows)
        if let landing = pendingLanding {
            if changeBlocks.isEmpty {
                selectAdjacentFile(landing, landingOnChange: true)
            } else {
                pendingLanding = nil
                currentChangeIndex = landing == .forward ? 0 : changeBlocks.count - 1
            }
        } else if let index = currentChangeIndex, index >= changeBlocks.count {
            currentChangeIndex = changeBlocks.isEmpty ? nil : changeBlocks.count - 1
        }
    }

    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let task, let worktreeURL else { return }

        guard await GitCLI.isGitRepository(at: worktreeURL) else {
            guard generation == refreshGeneration else { return }
            loadState = .notARepository
            files = []
            tree = []
            return
        }

        async let branchTask = GitCLI.currentBranch(at: worktreeURL)
        let baseline = await TaskBaseline.resolved(task: task, at: worktreeURL)
        guard generation == refreshGeneration else { return }

        let newFiles: [ChangesTreeFile]
        do {
            switch mode {
            case .all:
                baseRefLabel = baseline
                guard let baseline else {
                    newFiles = []
                    break
                }
                newFiles = try await GitCLI.workingTreeChanges(against: baseline, at: worktreeURL).map(Self.treeFile)
            case .committed:
                baseRefLabel = baseline
                guard let baseline else {
                    newFiles = []
                    break
                }
                newFiles = try await GitCLI.branchChanges(since: baseline, at: worktreeURL).map(Self.treeFile)
            case .uncommitted:
                baseRefLabel = "HEAD"
                newFiles = try await GitCLI.workingTreeChanges(against: "HEAD", at: worktreeURL).map(Self.treeFile)
            }
        } catch {
            guard generation == refreshGeneration else { return }
            loadState = .error(Self.describe(error))
            return
        }

        branchName = await branchTask
        guard generation == refreshGeneration else { return }

        files = newFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        tree = ChangesTreeBuilder.build(files)
        loadState = .loaded

        // Keep the selection if still present, else the first file; reload the diff either way since content may have changed.
        let selectionChanged = selectedPath == nil || !files.contains(where: { $0.path == selectedPath })
        if selectionChanged {
            selectedPath = tree.flatMap(\.leaves).first?.path
            resetChangeNavigation()
        }
        if selectionChanged || focusedRowID.map({ Self.ancestors(of: $0, in: tree) == nil }) ?? true {
            focusedRowID = selectedPath
        }
        await loadDiff()
    }

    private static func treeFile(_ change: GitCLI.BranchFileChange) -> ChangesTreeFile {
        ChangesTreeFile(
            path: change.path,
            origPath: change.origPath,
            kind: change.kind,
            linesAdded: change.linesAdded,
            linesRemoved: change.linesRemoved,
            isBinary: change.isBinary
        )
    }

    private func loadDiff() async {
        diffLoadGeneration += 1
        let generation = diffLoadGeneration

        guard let worktreeURL, let selectedPath, let file = files.first(where: { $0.path == selectedPath }) else {
            diffText = nil
            diffRows = []
            diffErrorMessage = nil
            resetChangeNavigation()
            return
        }
        let requestedMode = mode

        do {
            let diff: GitCLI.DiffText
            if file.kind == .untracked {
                diff = try await GitCLI.diffForUntracked(selectedPath, at: worktreeURL)
            } else {
                switch requestedMode {
                case .all, .uncommitted:
                    let ref = baseRefLabel ?? "HEAD"
                    diff = try await GitCLI.workingTreeDiff(
                        for: selectedPath, origPath: file.origPath, against: ref, fullFile: showsFullFile, at: worktreeURL
                    )
                case .committed:
                    guard let baseline = baseRefLabel else { return }
                    diff = try await GitCLI.branchDiff(
                        for: selectedPath, origPath: file.origPath, since: baseline, fullFile: showsFullFile, at: worktreeURL
                    )
                }
            }
            // A newer `loadDiff()` may have finished meanwhile; the generation counter catches even a reselection of the same path.
            guard generation == diffLoadGeneration else { return }
            diffText = diff
            diffRows = diff.isBinary ? [] : UnifiedDiffRenderer.parse(diff.text)
            diffErrorMessage = nil
            updateChangeBlocks()
        } catch {
            guard generation == diffLoadGeneration else { return }
            diffText = nil
            diffRows = []
            diffErrorMessage = Self.describe(error)
            resetChangeNavigation()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GitCLI.CommandError {
            return error.description
        }
        return String(describing: error)
    }
}
