import Foundation
import GRDB

/// One agent session belonging to a task: its transcript on disk, when it started,
/// and whether it is the active session.
public struct Conversation: Identifiable, Equatable, Codable, Sendable {
    public var id: Int64?
    public var taskId: Int64
    /// The pi session id this conversation was launched under (see
    /// `PiSessionService`). Known immediately, before pi has written a
    /// transcript file to resolve `transcriptPath` from — this is what lets a
    /// relaunch resume the same session even while `transcriptPath` is still
    /// empty.
    public var sessionId: String
    /// Absolute path to the transcript JSONL file, or `""` until
    /// `PiSessionService.locateTranscript` has resolved it on disk.
    public var transcriptPath: String
    public var startedAt: Date
    public var isActive: Bool

    public init(
        id: Int64? = nil,
        taskId: Int64,
        sessionId: String = "",
        transcriptPath: String,
        startedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.isActive = isActive
    }
}

extension Conversation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "conversation"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let taskId = Column(CodingKeys.taskId)
        public static let sessionId = Column(CodingKeys.sessionId)
        public static let transcriptPath = Column(CodingKeys.transcriptPath)
        public static let startedAt = Column(CodingKeys.startedAt)
        public static let isActive = Column(CodingKeys.isActive)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Conversation {
    public static let task = belongsTo(TaskRecord.self)
}
