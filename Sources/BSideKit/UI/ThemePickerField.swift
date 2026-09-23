import GhosttyTheme
import SwiftUI

/// A searchable list over the full theme catalog (``ThemeCatalogSource``),
/// each row showing a small swatch strip so a name alone doesn't have to be
/// enough to judge a theme by. The catalog is large — several hundred
/// entries — so this is a filtered `List`, not a flat `Picker` menu.
struct ThemePickerField: View {
    @Binding var selection: String
    @State private var query = ""

    /// Popular themes first, then the rest; while searching, both sections
    /// are filtered and an emptied section is hidden.
    private var sections: [(title: String, themes: [GhosttyThemeDefinition])] {
        let matches: (GhosttyThemeDefinition) -> Bool = { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return [
            ("Popular", ThemeCatalogSource.featuredThemes().filter(matches)),
            ("All Themes", ThemeCatalogSource.otherThemes().filter(matches)),
        ].filter { !$0.themes.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
            List(
                selection: Binding<String?>(
                    get: { selection.isEmpty ? nil : selection },
                    set: { newValue in if let newValue { selection = newValue } }
                )
            ) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.themes, id: \.name) { definition in
                            ThemeSwatchRow(definition: definition)
                                .tag(definition.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 180)
        }
    }
}

/// One catalog row: the theme's name next to a strip of swatches sampled
/// from its background, foreground, and ANSI colours 1–6.
private struct ThemeSwatchRow: View {
    let definition: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 8) {
            swatchStrip
            Text(definition.name)
                .lineLimit(1)
        }
    }

    private var swatchStrip: some View {
        HStack(spacing: 1) {
            swatch(RGBColor(hex: definition.background).color)
            swatch(RGBColor(hex: definition.foreground).color)
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { index in
                if let hex = definition.palette[index] {
                    swatch(RGBColor(hex: hex).color)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func swatch(_ color: Color) -> some View {
        color.frame(width: 10, height: 16)
    }
}
