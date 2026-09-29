import Foundation
import HighlightSwift

enum DiffLanguageDetector {
    static func language(forPath path: String) -> HighlightLanguage? {
        let name = (path as NSString).lastPathComponent
        if let byName = languagesByFileName[name.lowercased()] {
            return byName
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languagesByExtension[ext]
    }

    private static let languagesByFileName: [String: HighlightLanguage] = [
        "dockerfile": .dockerfile,
        "makefile": .makefile,
    ]

    private static let languagesByExtension: [String: HighlightLanguage] = [
        "swift": .swift,
        "m": .objectiveC,
        "mm": .objectiveC,
        "h": .c,
        "c": .c,
        "cpp": .cPlusPlus,
        "cc": .cPlusPlus,
        "cxx": .cPlusPlus,
        "hpp": .cPlusPlus,
        "hh": .cPlusPlus,
        "cs": .cSharp,
        "py": .python,
        "rb": .ruby,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "scala": .scala,
        "js": .javaScript,
        "mjs": .javaScript,
        "cjs": .javaScript,
        "jsx": .javaScript,
        "ts": .typeScript,
        "tsx": .typeScript,
        "php": .php,
        "pl": .perl,
        "sh": .bash,
        "bash": .bash,
        "zsh": .bash,
        "json": .json,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "html": .html,
        "htm": .html,
        "xml": .html,
        "css": .css,
        "scss": .scss,
        "less": .less,
        "sql": .sql,
        "md": .markdown,
        "markdown": .markdown,
        "lua": .lua,
        "r": .r,
        "dart": .dart,
        "ex": .elixir,
        "exs": .elixir,
        "erl": .erlang,
        "hs": .haskell,
        "clj": .clojure,
        "cljs": .clojure,
        "gradle": .gradle,
        "graphql": .graphQL,
        "proto": .protocolBuffers,
        "tex": .latex,
        "jl": .julia,
        "nix": .nix,
        "vb": .visualBasic,
        "makefile": .makefile,
        "gherkin": .gherkin,
        "feature": .gherkin,
        "diff": .diff,
        "patch": .diff,
    ]
}
