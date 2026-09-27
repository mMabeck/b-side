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
        (query: "dash", higher: "dash-pi", lower: "b-side-dash-fork"),
        (query: "side", higher: "b-side", lower: "synsforum-internal-dashboard-editor"),
        (query: "s", higher: "a-side", lower: "aside"),
    ])
    func matchQualityOutranks(query: String, higher: String, lower: String) throws {
        let higherScore = try #require(FuzzyMatcher.score(query: query, candidate: higher))
        let lowerScore = try #require(FuzzyMatcher.score(query: query, candidate: lower))
        #expect(higherScore > lowerScore)
    }

    @Test("rank drops non-matching items and orders the rest best-first")
    func rankOrdersByScore() {
        let items = ["b-side-dash-fork", "dash-pi", "synsforum"]
        let ranked = FuzzyMatcher.rank(query: "dash", items: items) { [$0] }
        #expect(ranked == ["dash-pi", "b-side-dash-fork"])
    }
}
