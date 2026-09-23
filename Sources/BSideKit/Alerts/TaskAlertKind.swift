import Foundation

/// What kind of attention a terminal alert (desktop notification or bell)
/// asks for.
public enum TaskAlertKind: Equatable, Sendable {
    case question
    case finished
}

/// Classifies a terminal desktop notification's title/body text as a
/// question needing the user's attention or a plain "finished" notification.
/// Pure so it's directly testable without a live terminal.
public enum TaskAlertClassifier {
    /// Case-insensitive keywords whose presence in either the title or body
    /// marks a notification as a question rather than a "finished" one.
    /// Matches Pi's own notify extension: "Pi has a question" (title) and
    /// whatever question preview text follows in the body.
    static let questionKeywords = ["question", "input", "permission", "waiting"]

    public static func classify(title: String, body: String) -> TaskAlertKind {
        let haystack = "\(title) \(body)".lowercased()
        return questionKeywords.contains(where: haystack.contains) ? .question : .finished
    }
}

/// Debounces duplicate terminal alerts for the same task arriving within a
/// short window — a program can ring the bell several times in a row, or
/// OSC 777 and a bell can fire for the same underlying event.
public enum TaskAlertDebouncer {
    public static let interval: TimeInterval = 1.5

    /// Pure so it's directly testable: whether an event `interval` seconds
    /// after `previous` should be dropped as a duplicate.
    public static func isDebounced(previous: Date?, now: Date, interval: TimeInterval = TaskAlertDebouncer.interval) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous) < interval
    }
}
