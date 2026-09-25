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
    var store: ProjectsStore
    var onFinished: () -> Void

    private typealias Mode = TaskCreationMode

    @ObservedObject private var theme: GhosttyResolvedTheme = .shared

    /// The project this task will be created in. Defaults to the project the
    /// sheet was opened for, but changeable via `projectField`'s fuzzy search
    /// — every field below that depends on the project (base ref, branches,
    /// worktree/mode defaults) is re-seeded when this changes, in
    /// `applyProjectDefaults(_:)`.
    @State private var selectedProject: Project
    @State private var isProjectPickerOpen = false
    @State private var projectQuery = ""
    @State private var highlightedProjectIndex = 0
    @FocusState private var projectQueryFocused: Bool

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
        // Keyed on the selected project's id, so switching projects in
        // `projectField` reruns this rather than only firing once. The
        // `guard` after both awaits drops a stale load's results if the
        // project changed again before it finished.
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Task")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
            Text("in \(selectedProject.displayName)")
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
            formRow("Project") {
                projectField
            }

            formRow("Task name (optional)") {
                themedTextField("New Task", text: $name)
            }

            formRow("Use worktree") {
                worktreeToggleRow
            }

            if useWorktree {
                formRow("Start from") {
                    modeToggle
                }

                switch mode {
                case .newBranch:
                    formRow("Base ref") {
                        if baseRefOptions.isEmpty {
                            themedTextField("main", text: $baseRef)
                        } else {
                            baseRefPicker
                        }
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

    // MARK: - Project picker

    private var projectMatches: [Project] {
        FuzzyMatcher.rank(query: projectQuery, items: store.projects) { [$0.displayName, $0.path] }
    }

    /// The "Project" field: a themed menu-label button showing the current
    /// selection that swaps to a fuzzy-search text field plus a ranked
    /// dropdown while open, closed only by choosing a project or Escape (not
    /// by focus loss) so a click on a dropdown row is never raced against a
    /// focus-driven close.
    private var projectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isProjectPickerOpen {
                themedTextField("Search projects…", text: $projectQuery)
                    .focused($projectQueryFocused)
                    .accessibilityLabel("Search projects")
                    .onChange(of: projectQuery) { _, _ in highlightedProjectIndex = 0 }
                    .onKeyPress(.downArrow) {
                        guard !projectMatches.isEmpty else { return .ignored }
                        highlightedProjectIndex = min(highlightedProjectIndex + 1, projectMatches.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !projectMatches.isEmpty else { return .ignored }
                        highlightedProjectIndex = max(highlightedProjectIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard projectMatches.indices.contains(highlightedProjectIndex) else { return .ignored }
                        chooseProject(projectMatches[highlightedProjectIndex])
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        closeProjectPicker()
                        return .handled
                    }
                    .task { projectQueryFocused = true }

                projectDropdown
            } else {
                Button {
                    projectQuery = ""
                    highlightedProjectIndex = 0
                    isProjectPickerOpen = true
                } label: {
                    themedMenuLabel(selectedProject.displayName, isPlaceholder: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project")
                .accessibilityValue(selectedProject.displayName)
                .accessibilityHint("Change the project this task belongs to")
            }
        }
    }

    private var projectDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if projectMatches.isEmpty {
                Text("No matching projects")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textDisabled)
                    .padding(10)
            } else {
                ForEach(Array(projectMatches.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        chooseProject(candidate)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.displayName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.palette.textPrimary)
                                Text(candidate.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.palette.textSecondary)
                            }
                            Spacer()
                            if candidate.id == selectedProject.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.palette.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            index == highlightedProjectIndex
                                ? theme.palette.elevatedSurfaceBackground
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { highlightedProjectIndex = index }
                    }
                    .accessibilityLabel(candidate.displayName)
                    .accessibilityValue(candidate.id == selectedProject.id ? "Selected" : "")
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.palette.surfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.separator, lineWidth: 1)
        )
        .frame(maxHeight: 180)
    }

    private func chooseProject(_ candidate: Project) {
        closeProjectPicker()
        guard candidate.id != selectedProject.id else { return }
        selectedProject = candidate
        applyProjectDefaults(candidate)
    }

    private func closeProjectPicker() {
        isProjectPickerOpen = false
        projectQuery = ""
        highlightedProjectIndex = 0
        projectQueryFocused = false
    }

    /// Re-seeds every field that depends on the project when the selection
    /// changes in `projectField`: branches/base refs are reloaded by the
    /// `.task(id: selectedProject.id)` in `body` reacting to `selectedProject`
    /// changing, not here, so clearing them to empty just avoids showing the
    /// old project's options while that reload is in flight.
    private func applyProjectDefaults(_ project: Project) {
        baseRef = project.baseRef
        useWorktree = project.lastUseWorktree
            ?? ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path)).taskDefaults.useWorktree
        mode = project.lastTaskCreationMode.flatMap(Mode.init(rawValue:)) ?? .newBranch
        selectedBranch = nil
        branches = []
        baseRefOptions = []
    }

    private var modeToggle: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { candidate in
                modeToggleButton(candidate)
            }
        }
    }

    private var worktreeToggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            themedToggle(isOn: $useWorktree)
            if !useWorktree {
                Text("Runs in the project folder on its current branch.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
    }

    private func themedToggle(isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn.wrappedValue ? theme.palette.accent : theme.palette.elevatedSurfaceBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.palette.separator, lineWidth: isOn.wrappedValue ? 0 : 1)
                )
                .frame(width: 34, height: 20)
                .overlay(
                    Circle()
                        .fill(theme.palette.selectionForeground)
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: isOn.wrappedValue ? .trailing : .leading)
                )
        }
        .buttonStyle(.plain)
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

    private var branchPicker: some View {
        Menu {
            ForEach(branches) { branch in
                Button(TaskCreationValidation.displayName(for: branch)) {
                    selectedBranch = branch.name
                }
                .disabled(branch.isCheckedOut)
            }
        } label: {
            themedMenuLabel(selectedBranch ?? "Choose…", isPlaceholder: selectedBranch == nil)
        }
        .themedMenuStyle()
    }

    private var baseRefPicker: some View {
        Menu {
            ForEach(baseRefOptions, id: \.self) { ref in
                Button(ref) { baseRef = ref }
            }
        } label: {
            themedMenuLabel(baseRef.isEmpty ? "Choose…" : baseRef, isPlaceholder: baseRef.isEmpty)
        }
        .themedMenuStyle()
    }

    private func themedMenuLabel(_ text: String, isPlaceholder: Bool) -> some View {
        HStack {
            Text(text)
                .foregroundStyle(isPlaceholder ? theme.palette.textDisabled : theme.palette.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.palette.elevatedSurfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.separator, lineWidth: 1)
        )
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

private extension View {
    /// A `Menu` that renders its label exactly as built: `.borderlessButton`
    /// on macOS discards the label's own background, padding and frame and
    /// shows bare text, so the themed field box never appeared.
    func themedMenuStyle() -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
