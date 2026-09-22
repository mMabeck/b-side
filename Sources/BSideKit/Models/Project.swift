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

    public init(
        id: Int64? = nil,
        path: String,
        displayName: String,
        remote: String? = nil,
        baseRef: String = "main"
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.remote = remote
        self.baseRef = baseRef
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
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Project {
    public static let tasks = hasMany(TaskRecord.self)
}
