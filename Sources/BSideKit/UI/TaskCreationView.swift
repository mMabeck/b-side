import SwiftUI

/// Which branch a new task's worktree attaches to: a fresh branch cut from a
/// base ref, or an existing local branch.
public enum TaskCreationMode: String, CaseIterable, Identifiable, Sendable {
    case newBranch = "New Branch"
    case existingBranch = "Existing Branch"
    public var id: String { rawValue }
}

/// Pure validation and formatting rules for ``TaskCreationView``, kept free
/// of SwiftUI so they're directly unit-testable.
enum TaskCreationValidation {
    /// A blank task name falls back to a placeholder. With `useWorktree` off
    /// the task runs in place, so no base ref/branch is required either.
    static func canCreate(
        name: String,
        mode: TaskCreationMode,
        baseRef: String,
        selectedBranch: String?,
        useWorktree: Bool = true
    ) -> Bool {
        guard useWorktree else { return true }
        switch mode {
        case .newBranch:
            return !baseRef.trimmingCharacters(in: .whitespaces).isEmpty
        case .existingBranch:
            return selectedBranch != nil
        }
    }

    /// Shown but disabled if already checked out elsewhere, since a worktree can't reuse a live branch.
    static func displayName(for branch: TaskWorktreeService.BranchOption) -> String {
        guard let checkedOutAt = branch.checkedOutAt else { return branch.name }
        return "\(branch.name) (checked out at \(checkedOutAt))"
    }
}

/// Sheet for creating a task: name, base ref/branch, then a log panel of setup command output.
struct TaskCreationView: View {
    var store: ProjectsStore
    var onFinished: () -> Void

    private typealias Mode = TaskCreationMode

    @ObservedObject private var theme: GhosttyResolvedTheme = .shared

    /// Changeable via `projectField`; dependent fields are re-seeded in `applyProjectDefaults(_:)`.
    @State private var selectedProject: Project

    @State private var name = ""
    @State private var baseRef: String
    @State private var mode: Mode = .newBranch
    @State private var useWorktree: Bool
    @State private var branches: [TaskWorktreeService.BranchOption] = []
    @State private var baseRefOptions: [String] = []
    @State private var selectedBranch: String?

    @State private var isCreating = false
    @State private var isFinished = false
    @State private var logLines: [String] = []
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(project: Project, store: ProjectsStore, onFinished: @escaping () -> Void) {
        self.store = store
        self.onFinished = onFinished
        _selectedProject = State(initialValue: project)
        _baseRef = State(initialValue: project.baseRef)
        _useWorktree = State(
            initialValue: project.lastUseWorktree
                ?? ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path)).taskDefaults.useWorktree
        )
        _mode = State(
            initialValue: project.lastTaskCreationMode.flatMap(Mode.init(rawValue:)) ?? .newBranch
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCreating || isFinished || errorMessage != nil {
                    creationProgressView
                } else {
                    Form {
                        formSections
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("New Task")
            .navigationSubtitle(selectedProject.displayName)
            .toolbar {
                if isFinished || errorMessage != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if !isCreating {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .disabled(!canCreate)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .frame(width: 480)
        // The sheet gets its own `NSWindow`, so system-drawn text needs the palette applied to it directly too.
        .themedWindow(theme.palette)
        // The `guard` after both awaits drops a stale load if the project changed again before it finished.
        .task(id: selectedProject.id) {
            let project = selectedProject
            let loadedBranches = (try? await TaskWorktreeService.availableBranches(for: project)) ?? []
            var baseRefs = (try? await TaskWorktreeService.availableBaseRefs(for: project)) ?? []
            if !baseRefs.isEmpty, !baseRefs.contains(project.baseRef) {
                baseRefs.insert(project.baseRef, at: 0)
            }
            guard selectedProject.id == project.id, !Task.isCancelled else { return }
            branches = loadedBranches
            baseRefOptions = baseRefs
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var formSections: some View {
        Section {
            projectField
            TextField("Task Name (Optional)", text: $name, prompt: Text("New Task"))
        }

        Section {
            Toggle("Use Worktree", isOn: $useWorktree)
        } footer: {
            if !useWorktree {
                Text("Runs in the project folder on its current branch.")
            }
        }

        if useWorktree {
            Section {
                Picker("Start From", selection: $mode) {
                    ForEach(Mode.allCases) { candidate in
                        Text(candidate.rawValue).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .newBranch:
                    baseRefField
                case .existingBranch:
                    branchPicker
                }
            }
        }
    }

    // MARK: - Project picker

    private var projectIDBinding: Binding<Int64?> {
        Binding(
            get: { selectedProject.id },
            set: { newID in
                guard let newID, let candidate = store.projects.first(where: { $0.id == newID }),
                      candidate.id != selectedProject.id else { return }
                selectedProject = candidate
                applyProjectDefaults(candidate)
            }
        )
    }

    private var projectField: some View {
        Picker("Project", selection: projectIDBinding) {
            ForEach(store.projects) { project in
                Text(project.displayName).tag(project.id)
            }
        }
    }

    /// Branches/base refs are reloaded by `body`'s `.task(id:)`, not here; clearing them just avoids showing stale options while that reload is in flight.
    private func applyProjectDefaults(_ project: Project) {
        baseRef = project.baseRef
        useWorktree = project.lastUseWorktree
            ?? ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path)).taskDefaults.useWorktree
        mode = project.lastTaskCreationMode.flatMap(Mode.init(rawValue:)) ?? .newBranch
        selectedBranch = nil
        branches = []
        baseRefOptions = []
    }

    // MARK: - Branch / base ref

    /// A free-text field rather than a closed picker, so typing a name that
    /// isn't in `baseRefOptions` (yet, or ever) still works; the suggestions
    /// popover offers fuzzy-ranked existing refs without constraining input.
    private var baseRefField: some View {
        TextField("Base Ref", text: $baseRef, prompt: Text("main"))
            .textInputSuggestions {
                ForEach(baseRefSuggestions, id: \.self) { ref in
                    Text(ref).textInputCompletion(ref)
                }
            }
    }

    private var baseRefSuggestions: [String] {
        guard !baseRefOptions.isEmpty else { return [] }
        return FuzzyMatcher.rank(query: baseRef, items: baseRefOptions, text: { [$0] })
    }

    @ViewBuilder
    private var branchPicker: some View {
        if branches.isEmpty {
            Text("No local branches found.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Branch", selection: $selectedBranch) {
                Text("Choose…").tag(String?.none)
                ForEach(branches) { branch in
                    Text(TaskCreationValidation.displayName(for: branch))
                        .tag(Optional(branch.name))
                        .disabled(branch.isCheckedOut)
                }
            }
        }
    }

    private var canCreate: Bool {
        TaskCreationValidation.canCreate(
            name: name,
            mode: mode,
            baseRef: baseRef,
            selectedBranch: selectedBranch,
            useWorktree: useWorktree
        )
    }

    // MARK: - Creation progress

    private var creationProgressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            logPanel

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.statusError)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusLine: some View {
        if isCreating {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        } else if isFinished {
            Label("Task created", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.statusSuccess)
        } else if errorMessage != nil {
            Label("Creation failed", systemImage: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.statusError)
        }
    }

    private var logPanel: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(theme.palette.textSecondary)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: logLines.count) { _, newCount in
                    guard newCount > 0 else { return }
                    withAnimation {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 220)
    }

    // MARK: - Create

    private func create() {
        isCreating = true
        Task {
            do {
                let newBaseRef = useWorktree && mode == .newBranch ? baseRef : nil
                _ = try await store.createTask(
                    project: selectedProject,
                    name: name,
                    baseRef: newBaseRef,
                    existingBranch: useWorktree && mode == .existingBranch ? selectedBranch : nil,
                    useWorktree: useWorktree,
                    onOutput: { line in
                        Task { @MainActor in logLines.append(line) }
                    }
                )
                try? await store.rememberTaskCreationChoices(
                    project: selectedProject,
                    baseRef: newBaseRef,
                    useWorktree: useWorktree,
                    mode: mode
                )
                isCreating = false
                isFinished = true
                onFinished()
            } catch {
                isCreating = false
                errorMessage = String(describing: error)
            }
        }
    }
}
