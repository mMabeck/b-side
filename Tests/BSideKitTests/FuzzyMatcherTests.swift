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

    @Test("a prefix match scores higher than a contiguous match elsewhere in the string")
    func prefixOutranksContiguous() {
        let prefixScore = FuzzyMatcher.score(query: "dash", candidate: "dash-pi")
        let containsScore = FuzzyMatcher.score(query: "dash", candidate: "b-side-dash-fork")
        #expect(prefixScore != nil && containsScore != nil)
        #expect(prefixScore! > containsScore!)
    }

    @Test("a contiguous match scores higher than a scattered subsequence match")
    func contiguousOutranksScattered() {
        let contiguousScore = FuzzyMatcher.score(query: "side", candidate: "b-side")
        let scatteredScore = FuzzyMatcher.score(query: "side", candidate: "synsforum-internal-dashboard-editor")
        #expect(contiguousScore != nil && scatteredScore != nil)
        #expect(contiguousScore! > scatteredScore!)
    }

    @Test("a match starting at a word boundary scores higher than one that doesn't")
    func wordBoundaryOutranksMidWord() {
        let boundaryScore = FuzzyMatcher.score(query: "s", candidate: "a-side") // 's' right after '-'
        let midWordScore = FuzzyMatcher.score(query: "s", candidate: "aside") // 's' mid-word
        #expect(boundaryScore != nil && midWordScore != nil)
        #expect(boundaryScore! > midWordScore!)
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

    @Test("a blank query returns items unchanged, in their original order")
    func blankQueryReturnsOriginalOrder() {
        let items = ["zeta", "alpha", "beta"]
        #expect(FuzzyMatcher.rank(query: "", items: items) { [$0] } == items)
    }
}
