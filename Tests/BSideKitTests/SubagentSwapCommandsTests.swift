import SwiftUI
import Testing

@testable import BSideKit

/// Plain-data assertions on the swap shortcuts themselves, same rationale
/// (and same `.key.character`/`.modifiers` comparison, since `KeyboardShortcut`
/// itself isn't `Equatable`) as `WindowLayoutShortcut`'s own tests.
@Suite("SubagentSwapShortcut")
struct SubagentSwapCommandsTests {
    @Test("Show Main is control-command-0")
    func showMainShortcut() {
        #expect(SubagentSwapShortcut.showMain.key.character == "0")
        #expect(SubagentSwapShortcut.showMain.modifiers == [.control, .command])
    }

    @Test("Show Subagent N is control-command-N for N in 1...9")
    func showChildShortcuts() {
        for index in 0..<SubagentSwapShortcut.digitCount {
            let shortcut = SubagentSwapShortcut.showChild(atIndex: index)
            #expect(shortcut.key.character == Character("\(index + 1)"))
            #expect(shortcut.modifiers == [.control, .command])
        }
    }

    @Test("Next/Previous are control-command-]/[")
    func nextPreviousShortcuts() {
        #expect(SubagentSwapShortcut.next.key.character == "]")
        #expect(SubagentSwapShortcut.next.modifiers == [.control, .command])
        #expect(SubagentSwapShortcut.previous.key.character == "[")
        #expect(SubagentSwapShortcut.previous.modifiers == [.control, .command])
    }
}
