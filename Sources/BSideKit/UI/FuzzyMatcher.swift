import Foundation

/// Case-insensitive subsequence fuzzy matching for filtering short lists (e.g.
/// projects) against free-text queries, with a scoring/ranking split so a
/// caller can either check a single candidate or order a whole collection.
/// Pure and SwiftUI-free.
enum FuzzyMatcher {
    /// Scores how well `candidate` matches `query` as a case-insensitive
    /// subsequence: every character of `query`, in order, must appear
    /// somewhere in `candidate`. Returns `nil` when it doesn't match at all.
    /// Higher scores are better matches; a blank query matches everything
    /// with a score of `0`.
    ///
    /// Prefix and contiguous-substring matches score above scattered ones,
    /// and characters starting at a word boundary (start of string, or just
    /// after a space/`-`/`_`/`/`/`.`) earn a bonus, so "bs" ranks "B-Side"
    /// above a project whose name merely contains a scattered "b...s".
    static func score(query: String, candidate: String) -> Int? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return 0 }
        guard !candidate.isEmpty else { return nil }

        let queryChars = Array(trimmedQuery.lowercased())
        let candidateChars = Array(candidate.lowercased())

        var queryIndex = 0
        var matchedIndices: [Int] = []
        for (candidateIndex, char) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count else { break }
            if char == queryChars[queryIndex] {
                matchedIndices.append(candidateIndex)
                queryIndex += 1
            }
        }
        guard queryIndex == queryChars.count else { return nil }

        var score = 0

        let lowerCandidate = String(candidateChars)
        let lowerQuery = String(queryChars)
        if lowerCandidate.hasPrefix(lowerQuery) {
            score += 100
        } else if lowerCandidate.contains(lowerQuery) {
            score += 50
        }

        let boundaries: Set<Character> = [" ", "-", "_", "/", "."]
        for index in matchedIndices {
            if index == 0 || boundaries.contains(candidateChars[index - 1]) {
                score += 15
            }
        }

        for i in 1..<matchedIndices.count where matchedIndices.count > 1 {
            score -= (matchedIndices[i] - matchedIndices[i - 1] - 1)
        }

        // Prefer shorter, more specific candidates when matches otherwise tie.
        score -= candidateChars.count

        return score
    }

    /// Ranks `items` by the best score any of `text(item)`'s strings earns
    /// against `query`, dropping items that don't match at all. A blank
    /// query returns `items` unchanged, so an empty search field browses the
    /// full list in its original order.
    static func rank<Item>(query: String, items: [Item], text: (Item) -> [String]) -> [Item] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let scored: [(item: Item, score: Int)] = items.compactMap { item in
            let bestScore = text(item).compactMap { score(query: query, candidate: $0) }.max()
            guard let bestScore else { return nil }
            return (item, bestScore)
        }
        return scored.sorted { $0.score > $1.score }.map(\.item)
    }
}
