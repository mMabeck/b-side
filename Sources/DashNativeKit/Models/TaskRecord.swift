import Foundation
import GRDB

/// A unit of work, owning a branch and (normally) a worktree.
///
/// Named `TaskRecord` rather than `Task` to avoid colliding with Swift's
/// concurrency `Task` type.
public struct TaskRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: Int64?
    public var projectId: Int64
    public var name: String
    public var branchName: String
    public var branchCreatedByApp: Bool
    public var worktreePath: String
    public var harness: String
    public var permissionLevel: String
    public var contextPrompt: String?
    public var setupCommand: String?
    public var teardownCommand: String?
    public var archived: Bool
    public var sortPosition: Int

    public init(
        id: Int64? = nil,
        projectId: Int64,
        name: String,
        branchName: String,
        branchCreatedByApp: Bool = true,
        worktreePath: String,
        harness: String,
        permissionLevel: String,
        contextPrompt: String? = nil,
        setupCommand: String? = nil,
        teardownCommand: String? = nil,
        archived: Bool = false,
        sortPosition: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.branchName = branchName
        self.branchCreatedByApp = branchCreatedByApp
        self.worktreePath = worktreePath
        self.harness = harness
        self.permissionLevel = permissionLevel
        self.contextPrompt = contextPrompt
        self.setupCommand = setupCommand
        self.teardownCommand = teardownCommand
        self.archived = archived
        self.sortPosition = sortPosition
    }
}

extension TaskRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "task"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let projectId = Column(CodingKeys.projectId)
        public static let name = Column(CodingKeys.name)
        public static let branchName = Column(CodingKeys.branchName)
        public static let branchCreatedByApp = Column(CodingKeys.branchCreatedByApp)
        public static let worktreePath = Column(CodingKeys.worktreePath)
        public static let harness = Column(CodingKeys.harness)
        public static let permissionLevel = Column(CodingKeys.permissionLevel)
        public static let contextPrompt = Column(CodingKeys.contextPrompt)
        public static let setupCommand = Column(CodingKeys.setupCommand)
        public static let teardownCommand = Column(CodingKeys.teardownCommand)
        public static let archived = Column(CodingKeys.archived)
        public static let sortPosition = Column(CodingKeys.sortPosition)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension TaskRecord {
    public static let project = belongsTo(Project.self)
    public static let conversations = hasMany(Conversation.self)
}
