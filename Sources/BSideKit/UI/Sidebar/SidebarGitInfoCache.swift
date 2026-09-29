import Foundation

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
