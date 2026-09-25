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

        for i in matchedIndices.indices.dropFirst() {
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
    ///
    /// `secondaryText` strings (e.g. long paths) only match when they contain
    /// the query as a contiguous substring, and always rank below every
    /// `text` match: a scattered subsequence through a long path like
    /// `/Users/…/project` matches almost any short query, which would make
    /// filtering useless.
    static func rank<Item>(
        query: String,
        items: [Item],
        text: (Item) -> [String],
        secondaryText: (Item) -> [String] = { _ in [] }
    ) -> [Item] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return items }
        let lowerQuery = trimmedQuery.lowercased()
        let scored: [(item: Item, tier: Int, score: Int)] = items.compactMap { item in
            if let best = text(item).compactMap({ score(query: trimmedQuery, candidate: $0) }).max() {
                return (item, 1, best)
            }
            let substringHits = secondaryText(item).filter { $0.lowercased().contains(lowerQuery) }
            guard let shortest = substringHits.map(\.count).min() else { return nil }
            return (item, 0, -shortest)
        }
        // Stable on ties, so equally good matches keep their original order.
        return scored.enumerated().sorted { lhs, rhs in
            (lhs.element.tier, lhs.element.score, -lhs.offset) > (rhs.element.tier, rhs.element.score, -rhs.offset)
        }.map(\.element.item)
    }
}
