import AppKit
import SwiftUI

/// Applies a ``BSidePalette`` to the hosting `NSWindow`: real `NSAppearance`
/// (so system-drawn chrome, including Liquid Glass, matches), and a
/// transparent title bar. Traffic lights and standard window behaviour are
/// untouched.
struct ThemedWindowModifier: ViewModifier {
    let palette: BSidePalette

    func body(content: Content) -> some View {
        content.background(WindowAccessor(configure: apply))
    }

    private func apply(_ window: NSWindow) {
        // At the `NSApp` level too: menus/popovers/sheets from any window
        // resolve their own appearance from `NSApp.effectiveAppearance` when they have none of their own.
        NSApplication.shared.appearance = palette.preferredAppearance
        window.appearance = palette.preferredAppearance
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

extension View {
    /// Re-applies on every body update, so a theme change takes effect without restarting the app.
    func themedWindow(_ palette: BSidePalette) -> some View {
        modifier(ThemedWindowModifier(palette: palette))
    }
}

/// SwiftUI has no direct window accessor; places an invisible `NSView` that configures its window once attached.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    final class View: NSView {
        var configure: (NSWindow) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View(frame: .zero)
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: View, context: Context) {
        nsView.configure = configure
        if let window = nsView.window { configure(window) }
    }
}
