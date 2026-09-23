import Foundation
import Testing

@testable import BSideKit

@Suite("Task alert classification and debounce")
struct TaskAlertTests {
    // MARK: - Classification

    @Test("A title containing 'question' classifies as a question")
    func titleQuestionClassifiesAsQuestion() {
        #expect(TaskAlertClassifier.classify(title: "Pi has a question", body: "Ready?") == .question)
    }

    @Test("A plain 'finished' title classifies as finished")
    func finishedTitleClassifiesAsFinished() {
        #expect(TaskAlertClassifier.classify(title: "Pi finished", body: "Ready for your next prompt.") == .finished)
    }

    @Test("A 'failed' title with no question keyword classifies as finished")
    func failedTitleClassifiesAsFinished() {
        #expect(TaskAlertClassifier.classify(title: "Pi failed", body: "Something broke.") == .finished)
    }

    @Test("Classification is case-insensitive")
    func classificationIsCaseInsensitive() {
        #expect(TaskAlertClassifier.classify(title: "PI HAS A QUESTION", body: "") == .question)
    }

    @Test("A question keyword in the body alone is enough")
    func bodyKeywordAloneClassifiesAsQuestion() {
        #expect(TaskAlertClassifier.classify(title: "Ready", body: "Waiting on your input") == .question)
        #expect(TaskAlertClassifier.classify(title: "Ready", body: "Needs permission to continue") == .question)
    }

    @Test("A session-prefixed question title still classifies as a question")
    func sessionPrefixedTitleClassifiesAsQuestion() {
        #expect(TaskAlertClassifier.classify(title: "my-session — Pi has a question", body: "") == .question)
    }

    // MARK: - Debounce

    @Test("A duplicate within the debounce interval is dropped")
    func duplicateWithinIntervalIsDebounced() {
        let start = Date()
        #expect(TaskAlertDebouncer.isDebounced(previous: start, now: start.addingTimeInterval(0.5), interval: 1.5))
    }

    @Test("An event past the debounce interval is not dropped")
    func eventPastIntervalIsNotDebounced() {
        let start = Date()
        #expect(!TaskAlertDebouncer.isDebounced(previous: start, now: start.addingTimeInterval(1.6), interval: 1.5))
    }

    @Test("With no previous event, nothing is debounced")
    func noPreviousEventIsNeverDebounced() {
        #expect(!TaskAlertDebouncer.isDebounced(previous: nil, now: Date(), interval: 1.5))
    }
}
