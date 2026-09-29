import AppKit
import SwiftUI

struct ThemedWindowModifier: ViewModifier {
    let palette: BSidePalette

    func body(content: Content) -> some View {
        content.background(WindowAccessor(configure: apply))
    }

    private func apply(_ window: NSWindow) {
        // `NSApp` too: menus, popovers and sheets without their own appearance resolve from `NSApp.effectiveAppearance`.
        NSApplication.shared.appearance = palette.preferredAppearance
        window.appearance = palette.preferredAppearance
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

extension View {
    func themedWindow(_ palette: BSidePalette) -> some View {
        modifier(ThemedWindowModifier(palette: palette))
    }
}

/// SwiftUI has no direct window accessor; an invisible `NSView` configures its window once attached.
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
