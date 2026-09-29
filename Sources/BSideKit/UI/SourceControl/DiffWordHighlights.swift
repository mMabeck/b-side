import Foundation

enum DiffWordHighlights {
    struct Highlights: Equatable {
        let old: [NSRange]
        let new: [NSRange]
    }

    private static let maxTokensPerLine = 400
    private static let minCommonRatio = 0.3
    private static let maxRunSizeRatio = 3

    /// Pairs by index within each removed run followed directly by an added run; wildly unequal runs stay whole-line.
    static func pairs(in rows: [UnifiedDiffRenderer.Row]) -> [(removed: Int, added: Int)] {
        var result: [(removed: Int, added: Int)] = []
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .removed else {
                index += 1
                continue
            }
            let removedStart = index
            while index < rows.count, rows[index].kind == .removed { index += 1 }
            let addedStart = index
            while index < rows.count, rows[index].kind == .added { index += 1 }
            let removedCount = addedStart - removedStart
            let addedCount = index - addedStart
            guard addedCount > 0, max(removedCount, addedCount) <= maxRunSizeRatio * min(removedCount, addedCount) else { continue }
            for offset in 0..<min(removedCount, addedCount) {
                result.append((removedStart + offset, addedStart + offset))
            }
        }
        return result
    }

    /// `nil` when the lines are too dissimilar to be worth word-level emphasis.
    static func highlights(old: String, new: String) -> Highlights? {
        let oldTokens = tokens(in: old)
        let newTokens = tokens(in: new)
        guard oldTokens.count <= maxTokensPerLine, newTokens.count <= maxTokensPerLine else { return nil }

        let oldTexts = oldTokens.map(\.text)
        let newTexts = newTokens.map(\.text)
        let common = commonPairs(oldTexts, newTexts)

        let significant = { (text: String) in !text.allSatisfy(\.isWhitespace) }
        let commonSignificant = common.filter { significant(oldTexts[$0.old]) }.count
        let denominator = max(oldTexts.filter(significant).count, newTexts.filter(significant).count)
        guard denominator > 0, Double(commonSignificant) / Double(denominator) >= minCommonRatio else { return nil }

        let keptOld = Set(common.map(\.old))
        let keptNew = Set(common.map(\.new))
        return Highlights(
            old: mergedRanges(oldTokens.enumerated().filter { !keptOld.contains($0.offset) }.map(\.element.range)),
            new: mergedRanges(newTokens.enumerated().filter { !keptNew.contains($0.offset) }.map(\.element.range))
        )
    }

    private struct Token {
        let text: String
        let range: NSRange
    }

    private enum TokenClass { case word, space, punctuation }

    private static func tokenClass(_ character: Character) -> TokenClass {
        if character.isLetter || character.isNumber || character == "_" { return .word }
        if character.isWhitespace { return .space }
        return .punctuation
    }

    /// Punctuation splits per character so `()` vs `(x)` diffs cleanly.
    private static func tokens(in line: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var currentStart = 0
        var currentClass: TokenClass?
        var location = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(Token(text: current, range: NSRange(location: currentStart, length: location - currentStart)))
            current = ""
        }

        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            let isDecimalPoint = character == "." && current.last?.isNumber == true
                && characters.indices.contains(index + 1) && characters[index + 1].isNumber
            let kind = isDecimalPoint ? .word : tokenClass(character)
            if kind != currentClass || kind == .punctuation {
                flush()
                currentStart = location
                currentClass = kind
            }
            current.append(character)
            location += character.utf16.count
        }
        flush()
        return result
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, NSMaxRange(last) == range.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: last.length + range.length)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func commonPairs(_ a: [String], _ b: [String]) -> [(old: Int, new: Int)] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let middleA = Array(a[prefix..<(a.count - suffix)])
        let middleB = Array(b[prefix..<(b.count - suffix)])
        var table = Array(repeating: Array(repeating: 0, count: middleB.count + 1), count: middleA.count + 1)
        for i in stride(from: middleA.count - 1, through: 0, by: -1) {
            for j in stride(from: middleB.count - 1, through: 0, by: -1) {
                table[i][j] = middleA[i] == middleB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result = (0..<prefix).map { (old: $0, new: $0) }
        var i = 0
        var j = 0
        while i < middleA.count, j < middleB.count {
            if middleA[i] == middleB[j] {
                result.append((prefix + i, prefix + j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        result += (0..<suffix).map { (old: a.count - suffix + $0, new: b.count - suffix + $0) }
        return result
    }
}
