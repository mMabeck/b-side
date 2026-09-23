import SwiftUI

/// The theme catalog as a standard selectable `List`, grouped into dark and
/// light (``ThemeCatalogSource/groups``). A list rather than a menu `Picker`
/// so the arrow keys step through themes, each step applying live. Must not
/// be nested in a `Form`, where a `List` does not scroll reliably.
struct ThemeList: View {
    @Binding var selection: String?
    /// `true`/`false` shows only dark/light themes (one slot of the
    /// light/dark pair); `nil` shows both.
    var darkOnly: Bool?

    private var groups: [ThemeCatalogSource.Group] {
        ThemeCatalogSource.groups.filter { group in
            guard let darkOnly, let first = group.themes.first else { return true }
            return ThemeCatalogSource.isDark(first) == darkOnly
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.themes, id: \.name) { definition in
                            Text(definition.name)
                                .tag(definition.name)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }
}
