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
/// Lists the corpus via `GhosttyThemeCatalog.allThemes`, never `search("")`:
/// Foundation's `contains("")` is false, so an empty search matches nothing.
enum ThemeCatalogSource {
    /// Well-known themes pinned above the full alphabetical catalog, which
    /// otherwise opens on obscure names ("0x96f", "12-bit Rainbow") and
    /// buries these among ~480 entries. One dark and, where the family has
    /// one, one light variant each. Every name must exist in the catalog —
    /// `ThemeOverrideTests` guards against upstream renames.
    static let featuredNames: [String] = [
        "Catppuccin Mocha", "Catppuccin Latte",
        "TokyoNight", "TokyoNight Day",
        "Dracula",
        "Nord", "Nord Light",
        "Gruvbox Dark", "Gruvbox Light",
        "iTerm2 Solarized Dark", "iTerm2 Solarized Light",
        "Rose Pine", "Rose Pine Dawn",
        "Atom One Dark", "Atom One Light",
        "GitHub Dark Default", "GitHub Light Default",
        "Monokai Pro", "Monokai Pro Light",
        "Kanagawa Wave", "Kanagawa Lotus",
        "Everforest Dark Hard", "Everforest Light Med",
        "Ayu", "Ayu Light",
        "Night Owl",
        "Tomorrow Night", "Tomorrow",
        "Xcode Dark", "Xcode Light",
        "Apple System Colors", "Apple System Colors Light",
        "Zenburn",
    ]

    /// B-Side's own themes, then ``featuredNames`` in order.
    static func featuredThemes() -> [GhosttyThemeDefinition] {
        BSideBundledThemes.all + featuredNames.compactMap(GhosttyThemeCatalog.theme(named:))
    }

    /// The rest of the catalog, excluding anything already in
    /// ``featuredThemes()`` so each name appears once in the picker.
    static func otherThemes() -> [GhosttyThemeDefinition] {
        let featured = Set(featuredNames)
        return GhosttyThemeCatalog.allThemes.filter { !featured.contains($0.name) }
    }

    static func allThemes() -> [GhosttyThemeDefinition] {
        BSideBundledThemes.all + GhosttyThemeCatalog.allThemes
    }

    /// Whether a theme reads as dark, by the same background-luminance test
    /// ``BSidePalette/themed(from:)`` uses for the app's appearance.
    static func isDark(_ definition: GhosttyThemeDefinition) -> Bool {
        RGBColor(hex: definition.background).relativeLuminance < 0.5
    }

    /// One titled group of the theme list.
    struct Group: Identifiable {
        let title: String
        let themes: [GhosttyThemeDefinition]
        var id: String { title }
    }

    /// The theme list's sections: popular dark, popular light, then the
    /// rest of each. Computed once — classifying ~490 themes is not free and
    /// the catalog never changes at runtime.
    static let groups: [Group] = {
        let featured = featuredThemes()
        let other = otherThemes()
        return [
            Group(title: "Dark", themes: featured.filter(isDark)),
            Group(title: "Light", themes: featured.filter { !isDark($0) }),
            Group(title: "More Dark", themes: other.filter(isDark)),
            Group(title: "More Light", themes: other.filter { !isDark($0) }),
        ]
    }()

    static func theme(named name: String) -> GhosttyThemeDefinition? {
        BSideBundledThemes.all.first { $0.name == name } ?? GhosttyThemeCatalog.theme(named: name)
    }
}
