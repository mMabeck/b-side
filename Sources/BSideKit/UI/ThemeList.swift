import SwiftUI

/// The theme catalog as a standard selectable `List`:
/// ``ThemeCatalogSource/featuredThemes()`` in a "Popular" section above the
/// rest. A list rather than a menu `Picker` so the arrow keys step through
/// themes, each step applying live. Must not be nested in a `Form`, where a
/// `List` does not scroll reliably.
struct ThemeList: View {
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
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
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }
}
