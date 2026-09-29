import Foundation

public struct RunStatistics: Sendable, Equatable {
    public var turns: Int
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cost: Double
    public var contextTokens: Int
    public var model: String?

    public init(
        turns: Int = 0,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cost: Double = 0,
        contextTokens: Int = 0,
        model: String? = nil
    ) {
        self.turns = turns
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cost = cost
        self.contextTokens = contextTokens
        self.model = model
    }
}

public enum RunStatisticsFormatter {
    public static func format(_ usage: RunStatistics) -> String {
        var parts: [String] = []
        parts.append("\(usage.turns) turn\(usage.turns == 1 ? "" : "s")")
        if usage.input > 0 { parts.append("↑\(abbreviate(usage.input))") }
        if usage.output > 0 { parts.append("↓\(abbreviate(usage.output))") }
        if usage.cacheRead > 0 { parts.append("R\(abbreviate(usage.cacheRead))") }
        if usage.cacheWrite > 0 { parts.append("W\(abbreviate(usage.cacheWrite))") }
        if usage.cost > 0 { parts.append("$\(String(format: "%.4f", usage.cost))") }
        if usage.contextTokens > 0 { parts.append("ctx:\(abbreviate(usage.contextTokens))") }
        if let model = usage.model { parts.append(model) }
        return parts.joined(separator: " ")
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        return "\(minutes)m \(String(format: "%02d", remainingSeconds))s"
    }

    private static func abbreviate(_ value: Int) -> String {
        guard value >= 1000 else { return String(value) }
        let thousands = Double(value) / 1000
        if thousands >= 10 {
            return "\(Int(thousands.rounded()))k"
        }
        let rounded = (thousands * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))k"
        }
        return "\(rounded)k"
    }
}
