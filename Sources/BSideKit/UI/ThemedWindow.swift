import AppKit
import SwiftUI

struct ThemedWindowModifier: ViewModifier {
    let palette: BSidePalette

    func body(content: Content) -> some View {
        content.background(WindowAccessor(configure: apply))
    }

    private func apply(_ window: NSWindow) {
        // `NSApp` too: menus, popovers and sheets without their own appearance resolve from `NSApp.effectiveAppearance`.
        let appearance = palette.preferredAppearance
        if NSApplication.shared.appearance?.name != appearance?.name {
            NSApplication.shared.appearance = appearance
        }
        if window.appearance?.name != appearance?.name {
            window.appearance = appearance
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
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
            scheduleConfigure()
        }

        // Window setters relayout the frame view synchronously; doing that inside a SwiftUI
        // update re-enters the hosting view's graph and AttributeGraph aborts.
        func scheduleConfigure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.configure(window)
            }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View(frame: .zero)
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: View, context: Context) {
        nsView.configure = configure
        nsView.scheduleConfigure()
    }
}
