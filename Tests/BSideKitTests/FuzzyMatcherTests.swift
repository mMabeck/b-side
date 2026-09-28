import Testing

@testable import BSideKit

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test("matches are case-insensitive subsequences")
    func caseInsensitiveSubsequence() {
        #expect(FuzzyMatcher.score(query: "bsd", candidate: "B-Side") != nil)
        #expect(FuzzyMatcher.score(query: "BSD", candidate: "b-side") != nil)
    }

    @Test("Prefix beats contiguous, contiguous beats scattered, and word-boundary beats mid-word", arguments: [
        (query: "note", higher: "notes-app", lower: "b-side-notes-fork"),
        (query: "side", higher: "b-side", lower: "docs-internal-dashboard-editor"),
        (query: "s", higher: "a-side", lower: "aside"),
    ])
    func matchQualityOutranks(query: String, higher: String, lower: String) throws {
        let higherScore = try #require(FuzzyMatcher.score(query: query, candidate: higher))
        let lowerScore = try #require(FuzzyMatcher.score(query: query, candidate: lower))
        #expect(higherScore > lowerScore)
    }

    @Test("rank drops non-matching items and orders the rest best-first")
    func rankOrdersByScore() {
        let items = ["b-side-notes-fork", "notes-app", "website"]
        let ranked = FuzzyMatcher.rank(query: "note", items: items) { [$0] }
        #expect(ranked == ["notes-app", "b-side-notes-fork"])
    }
}
