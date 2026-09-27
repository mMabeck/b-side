import Foundation
import Testing

@testable import BSideKit

@Suite("Task alert classification and debounce")
struct TaskAlertTests {
    // MARK: - Classification

    @Test("Title/body keywords classify as question or finished, case-insensitively and regardless of session prefix", arguments: [
        (title: "Pi has a question", body: "Ready?", expected: TaskAlertKind.question),
        (title: "Pi finished", body: "Ready for your next prompt.", expected: TaskAlertKind.finished),
        (title: "Pi failed", body: "Something broke.", expected: TaskAlertKind.finished),
        (title: "PI HAS A QUESTION", body: "", expected: TaskAlertKind.question),
        (title: "Ready", body: "Waiting on your input", expected: TaskAlertKind.question),
        (title: "Ready", body: "Needs permission to continue", expected: TaskAlertKind.question),
        (title: "my-session — Pi has a question", body: "", expected: TaskAlertKind.question),
    ])
    func classification(title: String, body: String, expected: TaskAlertKind) {
        #expect(TaskAlertClassifier.classify(title: title, body: body) == expected)
    }

    // MARK: - Debounce

    @Test("A duplicate within the debounce interval is dropped")
    func duplicateWithinIntervalIsDebounced() {
        let start = Date()
        #expect(TaskAlertDebouncer.isDebounced(previous: start, now: start.addingTimeInterval(0.5), interval: 1.5))
    }

}
