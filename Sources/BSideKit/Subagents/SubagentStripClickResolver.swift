import Foundation

/// `livePaneIDs` must be resolved at click time: Pi sends `begin` before `spawn`, so an earlier snapshot sees no panes.
public enum SubagentStripClickAction: Equatable {
    case showMain
    case toggle(childId: String)
    case highlight(childId: String)
}

public enum SubagentStripClickResolver {
    public static func resolve(_ hit: SubagentStripMouseParser.HitTestResult, livePaneIDs: Set<String>) -> SubagentStripClickAction {
        switch hit {
        case .mainHint:
            return .showMain
        case .card(let childId):
            return livePaneIDs.contains(childId) ? .toggle(childId: childId) : .highlight(childId: childId)
        }
    }
}
