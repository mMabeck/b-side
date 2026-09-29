import Foundation

/// Inclusive row range of consecutive added/removed rows.
struct DiffChangeBlock: Equatable, Sendable {
    let firstRow: Int
    let lastRow: Int

    static func blocks(in rows: [UnifiedDiffRenderer.Row]) -> [DiffChangeBlock] {
        var blocks: [DiffChangeBlock] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            let isChange = row.kind == .added || row.kind == .removed
            if isChange, start == nil { start = index }
            if !isChange, let begin = start {
                blocks.append(DiffChangeBlock(firstRow: begin, lastRow: index - 1))
                start = nil
            }
        }
        if let begin = start { blocks.append(DiffChangeBlock(firstRow: begin, lastRow: rows.count - 1)) }
        return blocks
    }
}

enum ChangeNavigation {
    enum Direction { case forward, backward }
    enum Step: Equatable {
        case block(Int)
        case adjacentFile
    }

    static func step(from current: Int?, count: Int, direction: Direction) -> Step {
        switch direction {
        case .forward:
            let next = current.map { $0 + 1 } ?? 0
            return next < count ? .block(next) : .adjacentFile
        case .backward:
            let previous = current.map { $0 - 1 } ?? count - 1
            return previous >= 0 && previous < count ? .block(previous) : .adjacentFile
        }
    }
}
