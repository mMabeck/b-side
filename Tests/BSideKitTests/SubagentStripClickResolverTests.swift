import Foundation
import Testing

@testable import BSideKit

@Suite("SubagentStripClickResolver")
struct SubagentStripClickResolverTests {
    @Test("The main hint always resolves to showMain, regardless of live panes")
    func mainHintShowsMain() {
        #expect(SubagentStripClickResolver.resolve(.mainHint, livePaneIDs: []) == .showMain)
        #expect(SubagentStripClickResolver.resolve(.mainHint, livePaneIDs: ["c1"]) == .showMain)
    }

    @Test("A card whose child has a live pane toggles")
    func cardWithLivePaneToggles() {
        let action = SubagentStripClickResolver.resolve(.card(childId: "c1"), livePaneIDs: ["c1"])
        #expect(action == .toggle(childId: "c1"))
    }

    @Test("A card whose child has no live pane highlights instead")
    func cardWithoutLivePaneHighlights() {
        let action = SubagentStripClickResolver.resolve(.card(childId: "c1"), livePaneIDs: [])
        #expect(action == .highlight(childId: "c1"))
    }

    @Test("The same click resolves differently once its pane goes live - must be looked up fresh, not cached at handler-install time")
    func sameClickResolvesDifferentlyOncePaneGoesLive() {
        let hit = SubagentStripMouseParser.HitTestResult.card(childId: "c1")
        #expect(SubagentStripClickResolver.resolve(hit, livePaneIDs: []) == .highlight(childId: "c1"))
        #expect(SubagentStripClickResolver.resolve(hit, livePaneIDs: ["c1"]) == .toggle(childId: "c1"))
    }
}
