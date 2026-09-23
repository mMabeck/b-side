import Testing

@testable import BSideKit

@Suite("TaskCreationValidation")
struct TaskCreationValidationTests {
    @Test("canCreate allows a blank name, which falls back to a placeholder")
    func allowsBlankName() {
        #expect(TaskCreationValidation.canCreate(name: "", mode: .newBranch, baseRef: "main", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "   ", mode: .newBranch, baseRef: "main", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", mode: .newBranch, baseRef: "main", selectedBranch: nil))
    }

    @Test("new-branch mode also requires a non-blank base ref")
    func newBranchRequiresBaseRef() {
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", mode: .newBranch, baseRef: "", selectedBranch: nil))
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", mode: .newBranch, baseRef: "   ", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", mode: .newBranch, baseRef: "main", selectedBranch: nil))
    }

    @Test("existing-branch mode requires a selected branch, ignoring baseRef")
    func existingBranchRequiresSelection() {
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", mode: .existingBranch, baseRef: "", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", mode: .existingBranch, baseRef: "", selectedBranch: "feature/x"))
    }

    @Test("turning worktree off requires neither a base ref nor a selected branch")
    func worktreeOffSkipsBranchRequirements() {
        #expect(
            TaskCreationValidation.canCreate(
                name: "", mode: .newBranch, baseRef: "", selectedBranch: nil, useWorktree: false
            )
        )
        #expect(
            TaskCreationValidation.canCreate(
                name: "Fix bug", mode: .existingBranch, baseRef: "", selectedBranch: nil, useWorktree: false
            )
        )
    }

    @Test("displayName is just the branch name when it isn't checked out")
    func displayNameForFreeBranch() {
        let branch = TaskWorktreeService.BranchOption(name: "feature/x")
        #expect(TaskCreationValidation.displayName(for: branch) == "feature/x")
    }

    @Test("displayName notes where a checked-out branch already lives")
    func displayNameForCheckedOutBranch() {
        let branch = TaskWorktreeService.BranchOption(name: "feature/x", checkedOutAt: "/repo-worktrees/x")
        #expect(TaskCreationValidation.displayName(for: branch) == "feature/x (checked out at /repo-worktrees/x)")
    }
}
