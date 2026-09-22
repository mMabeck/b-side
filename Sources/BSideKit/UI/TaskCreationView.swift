import SwiftUI

/// Which branch a new task's worktree attaches to: a fresh branch cut from a
/// base ref, or an existing local branch.
enum TaskCreationMode: String, CaseIterable, Identifiable, Sendable {
    case newBranch = "New Branch"
    case existingBranch = "Existing Branch"
    var id: String { rawValue }
}

/// Pure validation and formatting rules for ``TaskCreationView``, kept free
/// of SwiftUI so they're directly unit-testable.
enum TaskCreationValidation {
    /// Whether the form has enough information to attempt `create()`. The
    /// task name may be left blank (it falls back to a placeholder). When
    /// `useWorktree` is off the task runs in place, so no base ref or branch
    /// is required either; otherwise a non-blank base ref (new branch) or a
    /// chosen branch (existing branch) is required.
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

    /// A branch's label in the existing-branch picker: its name, plus where
    /// it's already checked out if it is (those entries are shown but
    /// disabled, since a worktree can't reuse a branch that's live elsewhere).
    static func displayName(for branch: TaskWorktreeService.BranchOption) -> String {
        guard let checkedOutAt = branch.checkedOutAt else { return branch.name }
        return "\(branch.name) (checked out at \(checkedOutAt))"
    }
}

/// Sheet for creating a task: name, base ref (new branch) or an existing
/// branch to attach a worktree to, then a themed log panel of setup command
/// output while creation runs. Styled entirely from `GhosttyResolvedTheme`
/// like the rest of the app's chrome — see `SidebarView`/`ProjectDashboardView`
/// for the same `.plain`-button-over-palette-fill convention.
struct TaskCreationView: View {
    let project: Project
    var store: ProjectsStore
    var onFinished: () -> Void

    private typealias Mode = TaskCreationMode

    @ObservedObject private var theme: GhosttyResolvedTheme = .shared

    @State private var name = ""
    @State private var baseRef: String
    @State private var mode: Mode = .newBranch
    @State private var useWorktree: Bool
    @State private var branches: [TaskWorktreeService.BranchOption] = []
    @State private var selectedBranch: String?
    @State private var branchesLoaded = false

    @State private var isCreating = false
    @State private var isFinished = false
    @State private var logLines: [String] = []
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(project: Project, store: ProjectsStore, onFinished: @escaping () -> Void) {
        self.project = project
        self.store = store
        self.onFinished = onFinished
        _baseRef = State(initialValue: project.baseRef)
        let config = ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path))
        _useWorktree = State(initialValue: config.taskDefaults.useWorktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Group {
                if isCreating || isFinished || errorMessage != nil {
                    creationProgressView
                } else {
                    formView
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Rectangle()
                .fill(theme.palette.separator)
                .frame(height: 1)

            footer
        }
        .frame(width: 460)
        .background(theme.palette.windowBackground)
        // The sheet gets its own `NSWindow`, so it needs the palette applied
        // to that window too — not just a themed SwiftUI background — or the
        // system-drawn text inside it renders in light `aqua` over this dark
        // background.
        .themedWindow(theme.palette)
        .task(id: mode) {
            guard mode == .existingBranch, !branchesLoaded else { return }
            branchesLoaded = true
            branches = (try? await TaskWorktreeService.availableBranches(for: project)) ?? []
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Task")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
            Text("in \(project.displayName)")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            formRow("Task name (optional)") {
                themedTextField("New Task", text: $name)
            }

            formRow("Use worktree") {
                worktreeToggle
            }

            if useWorktree {
                formRow("Start from") {
                    modeToggle
                }

                switch mode {
                case .newBranch:
                    formRow("Base ref") {
                        themedTextField("main", text: $baseRef)
                    }
                case .existingBranch:
                    formRow("Branch") {
                        if branches.isEmpty {
                            Text("No local branches found.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.textDisabled)
                        } else {
                            branchPicker
                        }
                    }
                }
            }
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
            content()
        }
    }

    private func themedTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.elevatedSurfaceBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.palette.separator, lineWidth: 1)
            )
    }

    private var modeToggle: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { candidate in
                modeToggleButton(candidate)
            }
        }
    }

    private func modeToggleButton(_ candidate: Mode) -> some View {
        let isSelected = mode == candidate
        return Button {
            mode = candidate
        } label: {
            Text(candidate.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? theme.palette.selectionForeground : theme.palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.palette.accent : theme.palette.elevatedSurfaceBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.palette.separator, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Whether the task's setup runs in a fresh branch/worktree or in the
    /// project's own checkout, as a themed two-state control matching
    /// `modeToggle` rather than a stock `Toggle`.
    private var worktreeToggle: some View {
        HStack(spacing: 8) {
            worktreeToggleButton(true, label: "Worktree")
            worktreeToggleButton(false, label: "In place")
        }
    }

    private func worktreeToggleButton(_ candidate: Bool, label: String) -> some View {
        let isSelected = useWorktree == candidate
        return Button {
            useWorktree = candidate
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? theme.palette.selectionForeground : theme.palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.palette.accent : theme.palette.elevatedSurfaceBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.palette.separator, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var branchPicker: some View {
        Menu {
            ForEach(branches) { branch in
                Button(TaskCreationValidation.displayName(for: branch)) {
                    selectedBranch = branch.name
                }
                .disabled(branch.isCheckedOut)
            }
        } label: {
            HStack {
                Text(selectedBranch ?? "Choose…")
                    .foregroundStyle(selectedBranch == nil ? theme.palette.textDisabled : theme.palette.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.elevatedSurfaceBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.palette.separator, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var canCreate: Bool {
        TaskCreationValidation.canCreate(name: name, mode: mode, baseRef: baseRef, selectedBranch: selectedBranch, useWorktree: useWorktree)
    }

    // MARK: - Creation progress

    private var creationProgressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            logPanel

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.statusError)
            }
        }
    }

    private var logPanel: some View {
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
                .padding(10)
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.surfaceBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.palette.separator, lineWidth: 1)
            )
            .onChange(of: logLines.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if isCreating {
                ProgressView()
                    .controlSize(.small)
                Text("Creating…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            } else if isFinished {
                Label("Task created", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.statusSuccess)
            } else if errorMessage != nil {
                Label("Creation failed", systemImage: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.statusError)
            }

            Spacer()

            if isCreating || isFinished || errorMessage != nil {
                themedButton(isFinished || errorMessage != nil ? "Done" : "Cancel", isPrimary: true) {
                    dismiss()
                }
            } else {
                themedButton("Cancel", isPrimary: false) { dismiss() }
                themedButton("Create", isPrimary: true, isEnabled: canCreate, isDefaultAction: true) { create() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func themedButton(
        _ title: String,
        isPrimary: Bool,
        isEnabled: Bool = true,
        isDefaultAction: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPrimary ? theme.palette.selectionForeground : theme.palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isPrimary ? theme.palette.accent : theme.palette.elevatedSurfaceBackground)
                )
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)

        return Group {
            if isDefaultAction {
                button.keyboardShortcut(.defaultAction)
            } else {
                button
            }
        }
    }

    // MARK: - Create

    private func create() {
        isCreating = true
        Task {
            do {
                _ = try await store.createTask(
                    project: project,
                    name: name,
                    baseRef: useWorktree && mode == .newBranch ? baseRef : nil,
                    existingBranch: useWorktree && mode == .existingBranch ? selectedBranch : nil,
                    useWorktree: useWorktree,
                    onOutput: { line in
                        Task { @MainActor in logLines.append(line) }
                    }
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
