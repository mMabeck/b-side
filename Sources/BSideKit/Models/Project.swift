import Foundation
import GRDB

/// A local git repository the user has added. Tasks branch from and are compared
/// against `baseRef` (usually `main`).
public struct Project: Identifiable, Equatable, Codable, Sendable {
    public var id: Int64?
    public var path: String
    public var displayName: String
    public var remote: String?
    public var baseRef: String
    /// Last `useWorktree` choice made in the New Task sheet for this
    /// project. `nil` until a task has been created, falling back to the
    /// project's `ProjectConfig` default.
    public var lastUseWorktree: Bool?
    /// Last `TaskCreationMode` raw value chosen in the New Task sheet.
    public var lastTaskCreationMode: String?

    public init(
        id: Int64? = nil,
        path: String,
        displayName: String,
        remote: String? = nil,
        baseRef: String = "main",
        lastUseWorktree: Bool? = nil,
        lastTaskCreationMode: String? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.remote = remote
        self.baseRef = baseRef
        self.lastUseWorktree = lastUseWorktree
        self.lastTaskCreationMode = lastTaskCreationMode
    }
}

extension Project: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "project"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let path = Column(CodingKeys.path)
        public static let displayName = Column(CodingKeys.displayName)
        public static let remote = Column(CodingKeys.remote)
        public static let baseRef = Column(CodingKeys.baseRef)
        public static let lastUseWorktree = Column(CodingKeys.lastUseWorktree)
        public static let lastTaskCreationMode = Column(CodingKeys.lastTaskCreationMode)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Project {
    public static let tasks = hasMany(TaskRecord.self)
}
