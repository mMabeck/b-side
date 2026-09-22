import Foundation
import Testing

@testable import DashNativeKit

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

    @Test("Pluralises turns")
    func pluralisesTurns() {
        let usage = RunStatistics(turns: 3)
        #expect(RunStatisticsFormatter.format(usage) == "3 turns")
    }

    @Test("Formats cost to 4 decimal places")
    func formatsCost() {
        let usage = RunStatistics(turns: 1, cost: 0.12345)
        #expect(RunStatisticsFormatter.format(usage) == "1 turn $0.1235")
    }

    @Test("Includes cache reads with an R prefix")
    func includesCacheReads() {
        let usage = RunStatistics(turns: 1, cacheRead: 500)
        #expect(RunStatisticsFormatter.format(usage) == "1 turn R500")
    }

    @Test("Formats short durations in seconds")
    func shortDuration() {
        #expect(RunStatisticsFormatter.formatDuration(18) == "18s")
    }

    @Test("Formats durations over a minute as m and zero-padded seconds")
    func longDuration() {
        #expect(RunStatisticsFormatter.formatDuration(64) == "1m 04s")
    }
}
