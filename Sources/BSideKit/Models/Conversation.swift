import Foundation
import GRDB

public struct Conversation: Identifiable, Equatable, Codable, Sendable {
    public var id: Int64?
    public var taskId: Int64
    /// Known before pi writes a transcript, so a relaunch can resume the session while `transcriptPath` is still empty.
    public var sessionId: String
    /// `""` until `PiSessionService.locateTranscript` resolves it.
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
