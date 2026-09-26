import SwiftUI

/// Small pill button used in sheet headers/footers, themed from the current
/// palette rather than system `.bordered` styling — shared by `DiffSheet`
/// and `ChangesOverlaySheet` so their buttons never drift out of sync.
struct ThemedSheetButton: View {
    let title: String
    let palette: BSidePalette
    var isPrimary: Bool = false
    var isDefaultAction: Bool = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPrimary ? palette.selectionForeground : palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isPrimary ? palette.accent : palette.elevatedSurfaceBackground)
                )
        }
        .buttonStyle(.plain)

        if isDefaultAction {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }
}

/// Centred, secondary-text placeholder for a sheet's content area — "No
/// changes", "Binary file", a load error, etc. Shared by `DiffSheet` and
/// `ChangesOverlaySheet`.
struct SheetCenteredMessage: View {
    let message: String
    let palette: BSidePalette

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.windowBackground)
    }
}

/// Banner shown above a diff whose text was capped before reaching the
/// view — shared by `DiffSheet` and `ChangesOverlaySheet`.
struct SheetTruncationBanner: View {
    let palette: BSidePalette

    var body: some View {
        Text("Diff truncated — showing a partial view of a very large change.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(palette.statusNeedsAttention.opacity(0.18))
    }
}
