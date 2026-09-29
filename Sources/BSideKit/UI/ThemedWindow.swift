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

/// SwiftUI has no direct window accessor; an invisible `NSView` reads `.window` once attached.
struct WindowAccessor: NSViewRepresentable {
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
