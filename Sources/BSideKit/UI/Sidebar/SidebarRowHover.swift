import SwiftUI

struct SidebarRowHover: ViewModifier {
    let isSelected: Bool
    let palette: BSidePalette

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            // Drawn in the native selection's inset; skipped when selected, where it would stack on top.
            .listRowBackground(
                isHovering && !isSelected
                    ? RoundedRectangle(cornerRadius: 8).fill(palette.textPrimary.opacity(0.08)).padding(.horizontal, 10)
                    : nil
            )
    }
}

extension View {
    func sidebarRowHover(isSelected: Bool, palette: BSidePalette) -> some View {
        modifier(SidebarRowHover(isSelected: isSelected, palette: palette))
    }
}
