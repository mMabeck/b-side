import Foundation

enum FuzzyMatcher {
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

        score -= candidateChars.count

        return score
    }

    /// `secondaryText` only matches as a contiguous substring: a scattered subsequence through a long path matches almost anything.
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
        return scored.enumerated().sorted { lhs, rhs in
            (lhs.element.tier, lhs.element.score, -lhs.offset) > (rhs.element.tier, rhs.element.score, -rhs.offset)
        }.map(\.element.item)
    }
}
