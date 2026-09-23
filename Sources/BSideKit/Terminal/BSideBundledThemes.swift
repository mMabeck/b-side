import GhosttyTheme

/// The brand Ghostty themes documented in `docs/brand.md` and shipped as
/// installable config files at `assets/theme/b-side.conf` and
/// `b-side-paper.conf`. `GhosttyThemeCatalog` only knows the themes baked
/// into `libghostty-spm` itself — it has never heard of these — so a user
/// who has not copied those files into `~/.config/ghostty/themes/` could
/// otherwise never pick the brand look from the Appearance tab. Mirrored
/// here by hand from the `.conf` files (small, fixed brand colours, not
/// worth a resource-bundling step) so the picker can offer them regardless
/// of what is installed on disk.
enum BSideBundledThemes {
    static let bSide = GhosttyThemeDefinition(
        name: "B-Side",
        background: "16141c",
        foreground: "ede7d8",
        cursorColor: "ff6c2f",
        cursorText: "16141c",
        selectionBackground: "3f2417",
        selectionForeground: "f3eee2",
        palette: [
            0: "2a2732", 1: "f03c3e", 2: "68a84a", 3: "ffe028",
            4: "0074be", 5: "ff48b0", 6: "00a995", 7: "d8d2c2",
            8: "4a4554", 9: "ff6c6e", 10: "8dcb6c", 11: "ffee7a",
            12: "3fa3e0", 13: "ff7fc7", 14: "3fd0bc", 15: "f3eee2",
        ]
    )

    static let bSidePaper = GhosttyThemeDefinition(
        name: "B-Side Paper",
        background: "f3eee2",
        foreground: "26283e",
        cursorColor: "ff6c2f",
        cursorText: "f3eee2",
        selectionBackground: "ffd9c4",
        selectionForeground: "1a1820",
        palette: [
            0: "1a1820", 1: "d02c2e", 2: "4d8a33", 3: "b8880a",
            4: "0060a2", 5: "d62f92", 6: "00887a", 7: "6b6658",
            8: "8e887a", 9: "f03c3e", 10: "68a84a", 11: "d8a512",
            12: "0074be", 13: "ff48b0", 14: "00a995", 15: "26283e",
        ]
    )

    static let all: [GhosttyThemeDefinition] = [bSide, bSidePaper]
}

/// Theme lookup across both sources: the brand themes above, and
/// `GhosttyThemeCatalog`'s own corpus. The brand themes are listed first so
/// they surface at the top of an unfiltered Appearance-tab picker.
/// `GhosttyThemeCatalog` exposes no "list everything" API — only
/// `theme(named:)` and `search(_:)` — but an empty query matches every name
/// (`String.contains("")` is always true), so `search("")` doubles as that.
enum ThemeCatalogSource {
    static func allThemes() -> [GhosttyThemeDefinition] {
        BSideBundledThemes.all + GhosttyThemeCatalog.search("")
    }

    static func theme(named name: String) -> GhosttyThemeDefinition? {
        BSideBundledThemes.all.first { $0.name == name } ?? GhosttyThemeCatalog.theme(named: name)
    }
}
