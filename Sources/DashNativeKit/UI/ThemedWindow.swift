import AppKit
import SwiftUI

/// Applies a ``DashPalette`` to the `NSWindow` hosting a SwiftUI scene: real
/// `NSAppearance` (so system-drawn chrome — scrollbars, menus, text-field
/// carets, focus rings, the traffic-light area — matches instead of staying
/// light), window background colour, and a transparent title bar that blends
/// into the themed content instead of sitting as a separate white strip.
/// Traffic lights and standard window behaviour are untouched — this only
/// recolours the window macOS already draws.
struct ThemedWindowModifier: ViewModifier {
    let palette: DashPalette

    func body(content: Content) -> some View {
        content.background(WindowAccessor(configure: apply))
    }

    private func apply(_ window: NSWindow) {
        window.appearance = palette.preferredAppearance
        window.backgroundColor = NSColor(palette.windowBackground)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // `NavigationSplitView`'s sidebar columns are backed by a system
        // `NSVisualEffectView` (macOS's "sidebar" vibrancy material). That
        // material follows the window's key/active state and, while
        // inactive, blends toward a near-white tint regardless of the
        // window's appearance or any SwiftUI colour drawn on top — the exact
        // "dark terminal in a white app" seam this change exists to close.
        // Forcing every such view to an opaque, always-"active" content
        // material makes the sidebar render the flat themed colour SwiftUI
        // asked for, in every window-focus state, not just when key.
        if let contentView = window.contentView {
            neutralizeVibrancy(in: contentView)
        }
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let contentView = window?.contentView else { return }
                neutralizeVibrancy(in: contentView)
            }
        }
    }
}

@MainActor
private func neutralizeVibrancy(in view: NSView) {
    if let effectView = view as? NSVisualEffectView {
        effectView.state = .active
        effectView.material = .contentBackground
    }
    for subview in view.subviews {
        neutralizeVibrancy(in: subview)
    }
}

extension View {
    /// Themes the window hosting this view. Re-applies on every body update,
    /// so a theme change (e.g. the user edits their Ghostty config) takes
    /// effect without restarting the app.
    func themedWindow(_ palette: DashPalette) -> some View {
        modifier(ThemedWindowModifier(palette: palette))
    }
}

/// Bridges to the hosting `NSWindow`. SwiftUI has no direct window accessor,
/// so this places an invisible `NSView` and reads `.window` once it is
/// attached to the view hierarchy.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [configure] in
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [configure] in
            if let window = nsView.window {
                configure(window)
            }
        }
    }
}
