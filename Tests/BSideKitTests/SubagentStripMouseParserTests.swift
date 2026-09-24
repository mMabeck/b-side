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

    @Test("A release sequence parses with isPress false")
    func parsesRelease() {
        let data = Data("\u{1B}[<0;12;3m".utf8)
        let events = SubagentStripMouseParser.parse(data)
        #expect(events == [.init(button: 0, column: 12, row: 3, isPress: false)])
    }

    @Test("Multiple sequences in one buffer all parse")
    func parsesMultipleSequences() {
        let data = Data("\u{1B}[<0;1;1M\u{1B}[<0;1;1m\u{1B}[<0;40;3M".utf8)
        let events = SubagentStripMouseParser.parse(data)
        #expect(events.count == 3)
        #expect(events.last == .init(button: 0, column: 40, row: 3, isPress: true))
    }

    @Test("Non-mouse bytes produce no events")
    func nonMouseBytesIgnored() {
        let data = Data("hello\r\n".utf8)
        #expect(SubagentStripMouseParser.parse(data).isEmpty)
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

    @Test("A click on the label row's main hint resolves to .mainHint")
    func hitTestMainHint() {
        let result = SubagentStripRenderer.Result(
            lines: [],
            slots: [.init(childId: "a", columnRange: 0..<30)],
            mainHintRange: 60..<70
        )
        let row = SubagentStripRenderer.cardRowCount + 1 // 1-based
        let hit = SubagentStripMouseParser.hitTest(column: 65, row: row, result: result)
        #expect(hit == .mainHint)
    }

    @Test("A click below the label row hits nothing")
    func hitTestBelowStripMisses() {
        let result = SubagentStripRenderer.Result(
            lines: [],
            slots: [.init(childId: "a", columnRange: 0..<30)],
            mainHintRange: 60..<70
        )
        let row = SubagentStripRenderer.cardRowCount + 2
        #expect(SubagentStripMouseParser.hitTest(column: 65, row: row, result: result) == nil)
    }
}
