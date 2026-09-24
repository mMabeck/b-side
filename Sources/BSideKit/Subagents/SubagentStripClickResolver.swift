import Foundation

/// Pure mapping from a strip hit-test result to the swap action it should
/// trigger, given which child ids currently have a live pane. Split out of
/// `TaskTerminalAreaView.handle` so the "was this child live at the moment
/// of the click" decision is directly testable without a SwiftUI host —
/// the caller is responsible for resolving `livePaneIDs` fresh from
/// `SubagentPaneStore` at click time, not from a snapshot captured when the
/// click handler was installed (Pi sends `begin` before `spawn`, so a
/// snapshot taken too early sees no panes at all).
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
