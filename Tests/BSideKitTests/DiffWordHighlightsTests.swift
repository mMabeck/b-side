import Foundation
import Testing

@testable import BSideKit

@Suite struct DiffWordHighlightsTests {
    @Test(arguments: [
        ("let count = items.count", "let count = visible.count", ["items"], ["visible"]),
        ("foo(a, b)", "foo(a, b, c)", [], [", c"]),
        ("return x", "return x", [], []),
        ("alpha beta gamma", "one two three four", nil, nil),
    ] as [(String, String, [String]?, [String]?)])
    func highlightsChangedTokens(old: String, new: String, removed: [String]?, added: [String]?) throws {
        var budget = DiffWordHighlights.comparisonBudget
        let result = DiffWordHighlights.highlights(old: old, new: new, budget: &budget)
        guard let removed, let added else {
            #expect(result == nil)
            return
        }
        let result0 = try #require(result)
        #expect(result0.old.map { (old as NSString).substring(with: $0) } == removed)
        #expect(result0.new.map { (new as NSString).substring(with: $0) } == added)
    }

    @Test func changeNavigationWalksBlocksThenFiles() {
        let rows = " -+ + - ".map { character in
            let kind: UnifiedDiffRenderer.RowKind = character == "-" ? .removed : character == "+" ? .added : .context
            return UnifiedDiffRenderer.Row(kind: kind, oldLineNumber: nil, newLineNumber: nil, text: "")
        }
        let blocks = DiffChangeBlock.blocks(in: rows)
        #expect(blocks == [DiffChangeBlock(firstRow: 1, lastRow: 2), DiffChangeBlock(firstRow: 4, lastRow: 4), DiffChangeBlock(firstRow: 6, lastRow: 6)])
        #expect(ChangeNavigation.step(from: nil, count: 3, direction: .forward) == .block(0))
        #expect(ChangeNavigation.step(from: 2, count: 3, direction: .forward) == .adjacentFile)
        #expect(ChangeNavigation.step(from: nil, count: 3, direction: .backward) == .block(2))
        #expect(ChangeNavigation.step(from: 0, count: 3, direction: .backward) == .adjacentFile)
    }
}
