import GhosttyTheme
import SwiftUI

/// A searchable list over the full theme catalog (``ThemeCatalogSource``),
/// each row showing a small swatch strip so a name alone doesn't have to be
/// enough to judge a theme by. The catalog is large — several hundred
/// entries — so this is a filtered `List`, not a flat `Picker` menu.
struct ThemePickerField: View {
    @Binding var selection: String
    @State private var query = ""

    private var filtered: [GhosttyThemeDefinition] {
        let all = ThemeCatalogSource.allThemes()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
            List(
                filtered,
                selection: Binding<String?>(
                    get: { selection.isEmpty ? nil : selection },
                    set: { newValue in if let newValue { selection = newValue } }
                )
            ) { definition in
                ThemeSwatchRow(definition: definition)
                    .tag(definition.name)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 140)
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
