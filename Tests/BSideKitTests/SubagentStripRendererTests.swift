import Foundation
import Testing

@testable import BSideKit

@Suite("SubagentStripRenderer")
struct SubagentStripRendererTests {
    private func makeRun(id: String, agent: String = "explorer", label: String = "Task", state: ChildRunState = .active, tools: [String] = []) -> ChildRun {
        var run = ChildRun(id: id, taskId: 1, agent: agent, taskLabel: label, startedAt: Date(timeIntervalSinceReferenceDate: 0))
        run.toolLines = tools
        run.state = state
        if state == .completed || state == .failed {
            run.endedAt = Date(timeIntervalSinceReferenceDate: 10)
        }
        return run
    }

    @Test("No runs renders nothing")
    func emptyRunsRenderNothing() {
        let result = SubagentStripRenderer.render(runs: [], viewedChildId: nil, columns: 120, now: Date())
        #expect(result.lines.isEmpty)
        #expect(result.slots.isEmpty)
    }

    @Test("A width under the minimum card width never produces a line wider than the columns given")
    func narrowWidthClampsLineLength() {
        let run = makeRun(id: "c1")
        let columns = SubagentStripRenderer.minCardWidth - 5
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: columns, now: Date())
        #expect(result.lines.count == SubagentStripRenderer.totalRowCount)
        #expect(result.slots.isEmpty)
        for line in result.lines {
            #expect(Self.stripANSI(line).count == columns)
        }
    }

    private static func stripANSI(_ text: String) -> String {
        var result = ""
        var chars = text.makeIterator()
        while let char = chars.next() {
            if char == "\u{1B}" {
                while let next = chars.next(), next != "m" {}
                continue
            }
            result.append(char)
        }
        return result
    }

    @Test("A single run renders the fixed row count, top-to-bottom border then label row")
    func singleRunRowCount() {
        let run = makeRun(id: "c1")
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: 5))
        #expect(result.lines.count == SubagentStripRenderer.totalRowCount)
        #expect(result.slots.count == 1)
        #expect(result.slots[0].childId == "c1")
    }

    @Test("Every card renders the same number of lines regardless of tool-line count")
    func cardsAreEqualHeight() {
        let short = makeRun(id: "short", tools: [])
        let long = makeRun(id: "long", tools: ["a", "b", "c", "d", "e", "f"])
        let result = SubagentStripRenderer.render(runs: [short, long], viewedChildId: nil, columns: 200, now: Date())
        #expect(result.lines.count == SubagentStripRenderer.totalRowCount)
        #expect(result.slots.count == 2)
    }

    @Test("Cards are laid out side by side with equal width and a one-column gap")
    func cardsAreSideBySideEqualWidth() {
        let a = makeRun(id: "a")
        let b = makeRun(id: "b")
        let result = SubagentStripRenderer.render(runs: [a, b], viewedChildId: nil, columns: 122, now: Date())
        #expect(result.slots.count == 2)
        let widthA = result.slots[0].columnRange.count
        let widthB = result.slots[1].columnRange.count
        #expect(widthA == widthB)
        #expect(result.slots[0].columnRange.upperBound + 1 == result.slots[1].columnRange.lowerBound)
    }

    @Test("Cards below the minimum width are dropped and counted as '+N more' in the label row")
    func overflowCardsCountedAsMore() {
        let runs = (0..<10).map { makeRun(id: "c\($0)") }
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: nil, columns: 80, now: Date())
        #expect(result.slots.count < runs.count)
        let labelLine = result.lines[SubagentStripRenderer.cardRowCount]
        #expect(labelLine.contains("more"))
    }

    @Test("The viewed card's border uses double-line box-drawing characters")
    func viewedCardUsesDoubleBorder() {
        let run = makeRun(id: "c1")
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: "c1", columns: 120, now: Date())
        #expect(result.lines[0].contains("╔"))
        #expect(result.lines[SubagentStripRenderer.cardRowCount - 1].contains("╚"))
    }

    @Test("An unviewed card's border uses single-line box-drawing characters")
    func unviewedCardUsesSingleBorder() {
        let run = makeRun(id: "c1")
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date())
        #expect(result.lines[0].contains("┌"))
        #expect(result.lines[SubagentStripRenderer.cardRowCount - 1].contains("└"))
    }

    @Test("An active run's status row shows a spinner and elapsed time")
    func activeRunShowsSpinnerAndElapsed() {
        let run = makeRun(id: "c1", state: .active)
        let now = Date(timeIntervalSinceReferenceDate: 18)
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: now)
        let statusRow = result.lines[SubagentStripRenderer.cardRowCount - 2]
        #expect(statusRow.contains("working"))
        #expect(statusRow.contains("18s"))
    }

    @Test("A blocked run's status row asks for the user")
    func blockedRunShowsWaiting() {
        let run = makeRun(id: "c1", state: .blocked)
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: 7))
        let statusRow = result.lines[SubagentStripRenderer.cardRowCount - 2]
        #expect(statusRow.contains("waiting for you"))
    }

    @Test("A completed run's status row says done, with the recorded elapsed time")
    func completedRunShowsDone() {
        let run = makeRun(id: "c1", state: .completed)
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: 999))
        let statusRow = result.lines[SubagentStripRenderer.cardRowCount - 2]
        #expect(statusRow.contains("done"))
        #expect(statusRow.contains("10s"))
    }

    @Test("A failed run's status row says failed")
    func failedRunShowsFailed() {
        let run = makeRun(id: "c1", state: .failed)
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date())
        let statusRow = result.lines[SubagentStripRenderer.cardRowCount - 2]
        #expect(statusRow.contains("failed"))
    }

    @Test("The label row summarises run counts by state")
    func labelRowSummarisesCounts() {
        let runs = [
            makeRun(id: "a", state: .active),
            makeRun(id: "b", state: .blocked),
            makeRun(id: "c", state: .completed),
        ]
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: nil, columns: 200, now: Date())
        let labelLine = result.lines[SubagentStripRenderer.cardRowCount]
        #expect(labelLine.contains("1 running"))
        #expect(labelLine.contains("1 blocked"))
        #expect(labelLine.contains("1 done"))
    }

    @Test("The label row carries the click/main hint and reports its column range")
    func labelRowHasMainHint() throws {
        let run = makeRun(id: "c1")
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date())
        let labelLine = result.lines[SubagentStripRenderer.cardRowCount]
        #expect(labelLine.contains("main"))
        let hintRange = try #require(result.mainHintRange)
        #expect(hintRange.upperBound <= 120)
    }

    @Test("formatElapsed renders seconds under a minute, and minutes+seconds beyond it")
    func formatElapsed() {
        #expect(SubagentStripRenderer.formatElapsed(18) == "18s")
        #expect(SubagentStripRenderer.formatElapsed(64) == "1m 04s")
    }

    @Test("fit pads short text and clips long text to the exact width")
    func fitPadsAndClips() {
        #expect(SubagentStripRenderer.fit("hi", width: 5) == "hi   ")
        #expect(SubagentStripRenderer.fit("hello world", width: 5) == "hello")
    }
}
