import AppKit
import SwiftUI

/// Applies a ``BSidePalette`` to the `NSWindow` hosting a SwiftUI scene: real
/// `NSAppearance` (so system-drawn chrome — scrollbars, menus, text-field
/// carets, focus rings, the traffic-light area — matches instead of staying
/// light), window background colour, and a transparent title bar that blends
/// into the themed content instead of sitting as a separate white strip.
/// Traffic lights and standard window behaviour are untouched — this only
/// recolours the window macOS already draws.
struct ThemedWindowModifier: ViewModifier {
    let palette: BSidePalette

    func body(content: Content) -> some View {
        content.background(WindowAccessor(configure: apply))
    }

    private func apply(_ window: NSWindow) {
        window.appearance = palette.preferredAppearance
        window.backgroundColor = NSColor(palette.windowBackground)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // `NavigationSplitView`'s sidebar columns are backed by translucent
        // system chrome: on older AppKit this is an `NSVisualEffectView`
        // (macOS's "sidebar" vibrancy material), on the newer "Liquid Glass"
        // AppKit it's a private `BackdropView` sibling instead. Both follow
        // the window's key/active state and sample what's behind the window,
        // blending toward a near-white tint regardless of the window's
        // appearance or any SwiftUI colour drawn on top — the exact "dark
        // terminal in a white app" seam this change exists to close.
        // `neutralizeVibrancy` handles both: the `NSVisualEffectView` case is
        // forced to an opaque, always-"active" content material; `BackdropView`,
        // which has no such material to switch to, is hidden outright.
        // `NSContainerConcentricGlassEffectView` looks like the same family
        // by name but is not touched: on this SDK it's the container that
        // actually hosts the sidebar's real SwiftUI content, not a
        // decorative overlay, so hiding it would hide the content with it.
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

    // On the newer "Liquid Glass" AppKit chrome, the sidebar column's
    // translucent backing is a private `BackdropView` that samples whatever
    // is behind the window to render its blur. There is no public API to
    // retint it, and unlike `NSVisualEffectView` it has no "opaque content
    // material" to switch to. It is a purely decorative leaf — a sibling of
    // this app's own SwiftUI-drawn content, never an ancestor of it — so
    // hiding it removes only the vibrancy layer and leaves this app's themed
    // background exactly where it was drawn. `NSContainerConcentricGlassEffectView`
    // is deliberately *not* matched here even though its name suggests the
    // same family: on this SDK it is the actual container that hosts the
    // sidebar's real SwiftUI content (confirmed by walking the live view
    // hierarchy), so hiding it would hide the content along with the glass.
    let className = NSStringFromClass(type(of: view))
    if className.hasSuffix("BackdropView") {
        view.isHidden = true
    }

    for subview in view.subviews {
        neutralizeVibrancy(in: subview)
    }
}

extension View {
    /// Themes the window hosting this view. Re-applies on every body update,
    /// so a theme change (e.g. the user edits their Ghostty config) takes
    /// effect without restarting the app.
    func themedWindow(_ palette: BSidePalette) -> some View {
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
