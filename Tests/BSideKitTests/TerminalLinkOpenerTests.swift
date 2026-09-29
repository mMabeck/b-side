import Foundation
import Testing
@testable import BSideKit

struct TerminalLinkOpenerTests {
    @Test(
        "web links and plain files open; things that would run are revealed instead; relative text is ignored",
        arguments: [
            ("https://example.com/a?b=1", "open"),
            ("vscode://file/tmp/x.swift", "open"),
            ("/tmp/notes.md", "open"),
            ("file:///Applications/Calculator.app", "reveal"),
            ("/tmp/run.command", "reveal"),
            ("/bin/ls", "reveal"),
            ("src/main.swift", "none"),
        ]
    )
    func action(link: String, expected: String) {
        let result: String = switch TerminalLinkOpener.action(for: link) {
        case .open: "open"
        case .reveal: "reveal"
        case nil: "none"
        }
        #expect(result == expected)
    }
}
