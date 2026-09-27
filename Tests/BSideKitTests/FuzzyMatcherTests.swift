import Testing

@testable import BSideKit

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test("a blank query matches everything with a score of zero")
    func blankQueryMatchesEverything() {
        #expect(FuzzyMatcher.score(query: "", candidate: "B-Side") == 0)
        #expect(FuzzyMatcher.score(query: "   ", candidate: "B-Side") == 0)
    }

    @Test("matches are case-insensitive subsequences")
    func caseInsensitiveSubsequence() {
        #expect(FuzzyMatcher.score(query: "bsd", candidate: "B-Side") != nil)
        #expect(FuzzyMatcher.score(query: "BSD", candidate: "b-side") != nil)
    }

    @Test("a query whose characters aren't all present, in order, doesn't match")
    func nonMatchingQueryReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "B-Side") == nil)
        #expect(FuzzyMatcher.score(query: "sb", candidate: "B-Side") == nil) // wrong order
    }

    @Test("an empty candidate never matches a non-blank query")
    func emptyCandidateDoesNotMatch() {
        #expect(FuzzyMatcher.score(query: "a", candidate: "") == nil)
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

    @Test("rank checks every string a candidate offers and keeps the best score")
    func rankChecksAllFields() {
        struct Candidate { let name: String; let path: String }
        let items = [
            Candidate(name: "Personal Site", path: "/Users/me/code/dash-pi"),
            Candidate(name: "Other", path: "/Users/me/code/other"),
        ]
        let ranked = FuzzyMatcher.rank(query: "dash", items: items) { [$0.name, $0.path] }
        #expect(ranked.map(\.name) == ["Personal Site"])
    }

    @Test("secondary text matches only as a substring, and ranks below name matches")
    func secondaryTextIsSubstringOnly() {
        struct Candidate { let name: String; let path: String }
        let items = [
            Candidate(name: "rotmg-rl", path: "/Users/me/Documents/rotmg-rl"),
            Candidate(name: "dotfiles", path: "/Users/me/Claude/dotfiles"),
            Candidate(name: "b-side", path: "/Users/me/Claude/b-side"),
        ]
        let rank = { (query: String) in
            FuzzyMatcher.rank(query: query, items: items, text: { [$0.name] }, secondaryText: { [$0.path] })
                .map(\.name)
        }
        // "bsd" is a scattered subsequence of every path ("/Users/..."),
        // but should only hit the name it fuzzily matches.
        #expect(rank("bsd") == ["b-side"])
        // A contiguous path fragment still finds projects, shorter paths first…
        #expect(rank("claude") == ["b-side", "dotfiles"])
        // …and name hits always outrank path-only hits.
        #expect(rank("d") == ["dotfiles", "b-side", "rotmg-rl"])
    }

    @Test("a blank query returns items unchanged, in their original order")
    func blankQueryReturnsOriginalOrder() {
        let items = ["zeta", "alpha", "beta"]
        #expect(FuzzyMatcher.rank(query: "", items: items) { [$0] } == items)
    }
}
