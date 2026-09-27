import Foundation
import Testing

@testable import BSideKit

@Suite("SubagentStripMouseParser")
struct SubagentStripMouseParserTests {
    @Test("A press sequence parses into a MouseEvent")
    func parsesPress() {
        let data = Data("\u{1B}[<0;12;3M".utf8)
        let events = SubagentStripMouseParser.parse(data)
        #expect(events == [.init(button: 0, column: 12, row: 3, isPress: true)])
    }

    @Test("A click inside a card's column range hits that card")
    func hitTestFindsCard() {
        let result = SubagentStripRenderer.Result(
            lines: [],
            slots: [
                .init(childId: "a", columnRange: 0..<30),
                .init(childId: "b", columnRange: 31..<61),
            ],
            mainHintRange: nil
        )
        let hit = SubagentStripMouseParser.hitTest(column: 35, row: 2, result: result)
        #expect(hit == .card(childId: "b"))
    }

    @Test("A click in the gap between cards hits nothing")
    func hitTestGapMisses() {
        let result = SubagentStripRenderer.Result(
            lines: [],
            slots: [.init(childId: "a", columnRange: 0..<30), .init(childId: "b", columnRange: 31..<61)],
            mainHintRange: nil
        )
        #expect(SubagentStripMouseParser.hitTest(column: 31, row: 2, result: result) == nil)
    }
}
