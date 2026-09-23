import SwiftUI

/// A standard menu-style `Picker` over the theme catalog, with
/// ``ThemeCatalogSource/featuredThemes()`` in a "Popular" section above the
/// rest. The native menu scrolls and supports type-to-select, so the
/// ~490-entry catalog needs no custom list or search field.
struct ThemePickerField: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            // Tag for the unset (`""`) default, so the picker always has a
            // matching tag to display.
            Text("Choose…").tag("")
            Section("Popular") {
                ForEach(ThemeCatalogSource.featuredThemes(), id: \.name) { definition in
                    Text(definition.name).tag(definition.name)
                }
            }
            Section("All Themes") {
                ForEach(ThemeCatalogSource.otherThemes(), id: \.name) { definition in
                    Text(definition.name).tag(definition.name)
                }
            }
        }
        .pickerStyle(.menu)
    }
}
