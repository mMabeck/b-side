import Foundation

public enum TaskAlertKind: Equatable, Sendable {
    case question
    case finished
}

public enum TaskAlertClassifier {
    /// Matches Pi's notify extension: a "Pi has a question" title plus the question preview in the body.
    static let questionKeywords = ["question", "input", "permission", "waiting"]

    public static func classify(title: String, body: String) -> TaskAlertKind {
        let haystack = "\(title) \(body)".lowercased()
        return questionKeywords.contains(where: haystack.contains) ? .question : .finished
    }
}

public enum TaskAlertDebouncer {
    public static let interval: TimeInterval = 1.5

    public static func isDebounced(previous: Date?, now: Date, interval: TimeInterval = TaskAlertDebouncer.interval) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous) < interval
    }
}
