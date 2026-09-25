import Testing

@testable import BSideKit

/// Which project a bare "New Task"/Cmd+N opens the sheet for when nothing
/// selection-specific resolves a target — pure, no store or database needed.
@Suite("ProjectCommands default task-creation project")
struct ProjectCommandsDefaultTargetTests {
    private static let projectA = Project(id: 1, path: "/tmp/a", displayName: "a")
    private static let projectB = Project(id: 2, path: "/tmp/b", displayName: "b")

    @Test("prefers the selection's own target when there is one")
    func prefersSelectionTarget() {
        let result = ProjectCommands.defaultTaskCreationProject(
            selection: .project(Self.projectB),
            projects: [Self.projectA, Self.projectB]
        )
        #expect(result == Self.projectB)
    }

    @Test("falls back to the first project when nothing is selected")
    func fallsBackToFirstProject() {
        let result = ProjectCommands.defaultTaskCreationProject(
            selection: .none,
            projects: [Self.projectA, Self.projectB]
        )
        #expect(result == Self.projectA)
    }

    @Test("resolves to nil, so Cmd+N can no-op, when there are no projects at all")
    func nilWhenNoProjects() {
        let result = ProjectCommands.defaultTaskCreationProject(selection: .none, projects: [])
        #expect(result == nil)
    }
}
