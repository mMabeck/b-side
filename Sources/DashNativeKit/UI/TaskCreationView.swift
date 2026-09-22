import SwiftUI

/// Sheet for creating a task: name, base ref (new branch) or an existing branch
/// to attach a worktree to, then a plain log of setup command output while
/// creation runs. Deliberately plain controls — no custom layout — per the
/// native UI decisions for this stage.
struct TaskCreationView: View {
    let project: Project
    var store: ProjectsStore
    var onFinished: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case newBranch = "New Branch"
        case existingBranch = "Existing Branch"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var baseRef: String
    @State private var mode: Mode = .newBranch
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task in \(project.displayName)")
                .font(.headline)

            if isCreating || isFinished || errorMessage != nil {
                creationProgressView
            } else {
                formView
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: mode) {
            guard mode == .existingBranch, !branchesLoaded else { return }
            branchesLoaded = true
            branches = (try? await TaskWorktreeService.availableBranches(for: project)) ?? []
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Task name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Start from", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .newBranch:
                TextField("Base ref", text: $baseRef)
                    .textFieldStyle(.roundedBorder)
            case .existingBranch:
                if branches.isEmpty {
                    Text("No local branches found.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Branch", selection: $selectedBranch) {
                        Text("Choose…").tag(String?.none)
                        ForEach(branches) { branch in
                            Text(branch.isCheckedOut ? "\(branch.name) (checked out at \(branch.checkedOutAt!))" : branch.name)
                                .tag(String?.some(branch.name))
                                .disabled(branch.isCheckedOut)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .newBranch:
            return !baseRef.trimmingCharacters(in: .whitespaces).isEmpty
        case .existingBranch:
            return selectedBranch != nil
        }
    }

    private var creationProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .border(Color.secondary.opacity(0.3))

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isFinished || errorMessage != nil ? "Done" : "Cancel") {
                    dismiss()
                }
            }
        }
    }

    private func create() {
        isCreating = true
        Task {
            do {
                _ = try await store.createTask(
                    project: project,
                    name: name,
                    baseRef: mode == .newBranch ? baseRef : nil,
                    existingBranch: mode == .existingBranch ? selectedBranch : nil,
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
