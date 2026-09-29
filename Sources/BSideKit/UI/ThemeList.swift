import SwiftUI

/// A `List`, not a menu `Picker`, so arrow keys step through themes; don't nest it in a `Form`, where it won't scroll.
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
