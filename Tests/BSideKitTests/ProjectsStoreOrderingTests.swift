import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore`'s project reordering against a real in-memory
/// database, mirroring `ProjectsStoreSelectionTests`'s pattern: `start()`
/// and wait for `ValueObservation` before asserting.
@MainActor
@Suite("ProjectsStore project ordering")
struct ProjectsStoreOrderingTests {
    private func makeStore() async throws -> (store: ProjectsStore, projectA: Project, projectB: Project, projectC: Project) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

        let (projectA, projectB, projectC): (Project, Project, Project) = try await database.dbQueue.write { db in
            var projectA = Project(path: "/tmp/project-a", displayName: "A", baseRef: "main", sortOrder: 0)
            try projectA.insert(db)
            var projectB = Project(path: "/tmp/project-b", displayName: "B", baseRef: "main", sortOrder: 1)
            try projectB.insert(db)
            var projectC = Project(path: "/tmp/project-c", displayName: "C", baseRef: "main", sortOrder: 2)
            try projectC.insert(db)
            return (projectA, projectB, projectC)
        }

        store.start()
        try await waitUntil {
            store.projects.count == 3
        }
        return (store, projectA, projectB, projectC)
    }

    @Test("moveProjects updates in-memory order immediately and persists sortOrder to the database")
    func moveProjectsUpdatesInMemoryOrderAndPersists() async throws {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

        let (projectA, projectB, projectC): (Project, Project, Project) = try await database.dbQueue.write { db in
            var projectA = Project(path: "/tmp/project-a", displayName: "A", baseRef: "main", sortOrder: 0)
            try projectA.insert(db)
            var projectB = Project(path: "/tmp/project-b", displayName: "B", baseRef: "main", sortOrder: 1)
            try projectB.insert(db)
            var projectC = Project(path: "/tmp/project-c", displayName: "C", baseRef: "main", sortOrder: 2)
            try projectC.insert(db)
            return (projectA, projectB, projectC)
        }
        store.start()
        try await waitUntil { store.projects.count == 3 }
        #expect(store.projects.map(\.id) == [projectA.id, projectB.id, projectC.id])

        try await store.moveProjects(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(store.projects.map(\.id) == [projectB.id, projectC.id, projectA.id])

        let persisted = try await database.dbQueue.read { db in
            try Project.order(Project.Columns.sortOrder, Project.Columns.id).fetchAll(db)
        }
        #expect(persisted.map(\.id) == [projectB.id, projectC.id, projectA.id])
    }

    @Test("moveProject(direction: .up/.down) swaps with the adjacent neighbour")
    func moveProjectDirectionSwapsNeighbour() async throws {
        let (store, projectA, projectB, projectC) = try await makeStore()

        try await store.moveProject(projectB, direction: .up)
        try await waitUntil {
            store.projects.map(\.id) == [projectB.id, projectA.id, projectC.id]
        }

        try await store.moveProject(projectA, direction: .down)
        try await waitUntil {
            store.projects.map(\.id) == [projectB.id, projectC.id, projectA.id]
        }
    }

    @Test("moveProject(direction:) is a no-op at either end of the list")
    func moveProjectDirectionNoOpAtEnds() async throws {
        let (store, projectA, projectB, projectC) = try await makeStore()

        try await store.moveProject(projectA, direction: .up)
        #expect(store.projects.map(\.id) == [projectA.id, projectB.id, projectC.id])

        try await store.moveProject(projectC, direction: .down)
        #expect(store.projects.map(\.id) == [projectA.id, projectB.id, projectC.id])
    }

    @Test("addProject appends a new project after the current max sortOrder")
    func addProjectAppendsAtEnd() async throws {
        let (store, _, _, projectC) = try await makeStore()
        let repoURL = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(repoURL) }

        try await store.addProject(at: repoURL)

        try await waitUntil {
            store.projects.count == 4
        }
        #expect(store.projects.last?.id != projectC.id)
        #expect(store.projects.last?.path == repoURL.path)
    }
}
