import Testing

@testable import BSideKit

@Suite("TaskCreationValidation")
struct TaskCreationValidationTests {
    @Test("canCreate requires a non-blank name")
    func requiresNonBlankName() {
        #expect(!TaskCreationValidation.canCreate(name: "", useWorktree: true, mode: .newBranch, baseRef: "main", selectedBranch: nil))
        #expect(!TaskCreationValidation.canCreate(name: "   ", useWorktree: true, mode: .newBranch, baseRef: "main", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .newBranch, baseRef: "main", selectedBranch: nil))
    }

    @Test("new-branch mode also requires a non-blank base ref")
    func newBranchRequiresBaseRef() {
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .newBranch, baseRef: "", selectedBranch: nil))
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .newBranch, baseRef: "   ", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .newBranch, baseRef: "main", selectedBranch: nil))
    }

    @Test("existing-branch mode requires a selected branch, ignoring baseRef")
    func existingBranchRequiresSelection() {
        #expect(!TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .existingBranch, baseRef: "", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: true, mode: .existingBranch, baseRef: "", selectedBranch: "feature/x"))
    }

    @Test("without a worktree, only the name is required, regardless of mode or base ref/branch")
    func noWorktreeOnlyRequiresName() {
        #expect(!TaskCreationValidation.canCreate(name: "", useWorktree: false, mode: .newBranch, baseRef: "", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: false, mode: .newBranch, baseRef: "", selectedBranch: nil))
        #expect(TaskCreationValidation.canCreate(name: "Fix bug", useWorktree: false, mode: .existingBranch, baseRef: "", selectedBranch: nil))
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
