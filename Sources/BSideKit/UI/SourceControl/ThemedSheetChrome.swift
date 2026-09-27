import SwiftUI

/// Sheet footer/header action button, on native `.glass`/`.glassProminent`
/// styles tinted with the brand accent — shared by `DiffSheet`,
/// `ChangesOverlaySheet`, and `TaskCreationView` so their buttons never drift out of sync.
struct ThemedSheetButton: View {
    let title: String
    let palette: BSidePalette
    var isPrimary: Bool = false
    var isEnabled: Bool = true
    var isDefaultAction: Bool = false
    let action: () -> Void

    var body: some View {
        Group {
            if isDefaultAction {
                buttonContent.keyboardShortcut(.defaultAction)
            } else {
                buttonContent
            }
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var buttonContent: some View {
        if isPrimary {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
        } else {
            Button(title, action: action)
                .buttonStyle(.glass)
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
