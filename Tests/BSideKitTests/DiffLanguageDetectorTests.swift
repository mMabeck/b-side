import HighlightSwift
import Testing

@testable import BSideKit

struct DiffLanguageDetectorTests {
    @Test("Language is picked from the file extension, case-insensitively", arguments: [
        ("Sources/App.swift", HighlightLanguage.swift),
        ("script.PY", .python),
        ("index.tsx", .typeScript),
        ("styles.scss", .scss),
        ("README.md", .markdown),
        ("Dockerfile", .dockerfile),
        ("nested/path/Makefile", .makefile),
        ("no-extension", nil),
        ("unknown.zzz", nil),
    ])
    private func languageForPath(path: String, expected: HighlightLanguage?) {
        #expect(DiffLanguageDetector.language(forPath: path) == expected)
    }
}
