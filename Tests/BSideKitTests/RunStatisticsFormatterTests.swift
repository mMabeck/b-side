import Foundation
import Testing

@testable import BSideKit

@Suite("RunStatisticsFormatter")
struct RunStatisticsFormatterTests {
    @Test("Matches the documented example")
    func documentedExample() {
        let usage = RunStatistics(
            turns: 1,
            input: 2,
            output: 280,
            cacheWrite: 14000,
            contextTokens: 14000,
            model: "claude-bridge/claude-sonnet-5"
        )
        let formatted = RunStatisticsFormatter.format(usage)
        #expect(formatted == "1 turn ↑2 ↓280 W14k ctx:14k claude-bridge/claude-sonnet-5")
    }

    @Test("Pluralises turns, formats cost to 4 decimal places, and includes cache reads with an R prefix")
    func formatsTurnsCostAndCacheReads() {
        #expect(RunStatisticsFormatter.format(RunStatistics(turns: 3)) == "3 turns")
        #expect(RunStatisticsFormatter.format(RunStatistics(turns: 1, cost: 0.12345)) == "1 turn $0.1235")
        #expect(RunStatisticsFormatter.format(RunStatistics(turns: 1, cacheRead: 500)) == "1 turn R500")
    }

    @Test("Formats durations in seconds under a minute, and as m + zero-padded seconds beyond it")
    func formatsDuration() {
        #expect(RunStatisticsFormatter.formatDuration(18) == "18s")
        #expect(RunStatisticsFormatter.formatDuration(64) == "1m 04s")
    }
}
