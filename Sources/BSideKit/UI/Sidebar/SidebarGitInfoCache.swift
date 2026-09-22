import Foundation

/// Best-effort, non-blocking branch/dirty facts for the sidebar's project
/// rows, styled after cmux's project list (name / branch / path). Fetched
/// off the row's render path and cached; a missing value just means the row
/// shows one less line, never a blocked UI.
@MainActor
@Observable
public final class SidebarGitInfoCache {
    public struct ProjectInfo: Equatable, Sendable {
        public var branch: String?
        public var isDirty: Bool
    }

    public private(set) var infoByProject: [Int64: ProjectInfo] = [:]

    public init() {}

    public func info(forProject projectID: Int64?) -> ProjectInfo? {
        guard let projectID else { return nil }
        return infoByProject[projectID]
    }

    /// Kicks off an async refresh for `project`; a no-op if one is already
    /// cached from this launch, so scrolling the list doesn't refire git per
    /// frame.
    public func refresh(_ project: Project) {
        guard let id = project.id, infoByProject[id] == nil else { return }
        let path = URL(fileURLWithPath: project.path)
        Task { [weak self] in
            let branch = await GitCLI.currentBranch(at: path)
            let dirty = (try? await GitCLI.isWorkingTreeDirty(at: path)) ?? false
            self?.infoByProject[id] = ProjectInfo(branch: branch, isDirty: dirty)
        }
    }
}
