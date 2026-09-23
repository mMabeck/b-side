import SwiftUI

/// The theme catalog as a standard selectable `List`, grouped into dark and
/// light (``ThemeCatalogSource/groups``). A list rather than a menu `Picker`
/// so the arrow keys step through themes, each step applying live. Must not
/// be nested in a `Form`, where a `List` does not scroll reliably.
struct ThemeList: View {
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(ThemeCatalogSource.groups) { group in
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
