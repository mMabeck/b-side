import Foundation
import Testing

@testable import BSideKit

@Suite("Task-creation target resolution")
struct TaskCreationTargetTests {
    private static let project = Project(id: 1, path: "/tmp/project", displayName: "project")
    private static let otherProject = Project(id: 2, path: "/tmp/other", displayName: "other")
    private static let task = TaskRecord(
        id: 10, projectId: 1, name: "Task", branchName: "feature",
        worktreePath: "/tmp/project", harness: "claude", permissionLevel: "default"
    )

    @Test("With a task selected, targets that task's own project")
    func taskSelectedTargetsItsProject() {
        let selection = MainSelection.task(Self.task, Self.project)
        #expect(selection.taskCreationTarget == Self.project)
    }

    @Test("With only a project selected, targets that project")
    func projectSelectedTargetsItself() {
        let selection = MainSelection.project(Self.otherProject)
        #expect(selection.taskCreationTarget == Self.otherProject)
    }

    @Test("With nothing selected, resolves to no target so Cmd+N can no-op")
    func nothingSelectedTargetsNil() {
        let selection = MainSelection.none
        #expect(selection.taskCreationTarget == nil)
    }
}
