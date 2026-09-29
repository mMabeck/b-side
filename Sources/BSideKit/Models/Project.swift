import Foundation
import GRDB

public struct Project: Identifiable, Equatable, Codable, Sendable {
    public var id: Int64?
    public var path: String
    public var displayName: String
    public var remote: String?
    public var baseRef: String
    public var lastUseWorktree: Bool?
    public var lastTaskCreationMode: String?
    /// Lowest first; `addProject` gives a new project one past the current max.
    public var sortOrder: Int

    public init(
        id: Int64? = nil,
        path: String,
        displayName: String,
        remote: String? = nil,
        baseRef: String = "main",
        lastUseWorktree: Bool? = nil,
        lastTaskCreationMode: String? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.remote = remote
        self.baseRef = baseRef
        self.lastUseWorktree = lastUseWorktree
        self.lastTaskCreationMode = lastTaskCreationMode
        self.sortOrder = sortOrder
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
        public static let sortOrder = Column(CodingKeys.sortOrder)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Project {
    public static let tasks = hasMany(TaskRecord.self)
}
