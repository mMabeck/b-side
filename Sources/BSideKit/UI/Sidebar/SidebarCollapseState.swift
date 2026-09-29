import Foundation

public struct SidebarCollapseState: Equatable, Sendable {
    public var collapsedProjectIDs: Set<Int64>

    public init(collapsedProjectIDs: Set<Int64> = []) {
        self.collapsedProjectIDs = collapsedProjectIDs
    }

    public func isExpanded(_ projectID: Int64?) -> Bool {
        guard let projectID else { return true }
        return !collapsedProjectIDs.contains(projectID)
    }

    public mutating func setExpanded(_ expanded: Bool, for projectID: Int64) {
        if expanded {
            collapsedProjectIDs.remove(projectID)
        } else {
            collapsedProjectIDs.insert(projectID)
        }
    }
}

extension SidebarCollapseState: RawRepresentable {
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else {
            self.init(collapsedProjectIDs: [])
            return
        }
        let ids = rawValue.split(separator: ",").compactMap { Int64($0) }
        self.init(collapsedProjectIDs: Set(ids))
    }

    public var rawValue: String {
        collapsedProjectIDs.sorted().map(String.init).joined(separator: ",")
    }
}
