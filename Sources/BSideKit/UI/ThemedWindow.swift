import AppKit
import ObjectiveC
import SwiftUI

/// Applies a ``BSidePalette`` to the hosting `NSWindow`: real `NSAppearance`
/// (so system-drawn chrome matches), window background, and a transparent
/// title bar. Traffic lights and standard window behaviour are untouched.
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
        window.backgroundColor = NSColor(palette.windowBackground)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // `NavigationSplitView`'s sidebar columns are backed by translucent
        // system chrome (`NSVisualEffectView` on older AppKit, a private
        // `BackdropView` on "Liquid Glass"), sampling behind the window into a
        // near-white tint regardless of this app's own colours — the "dark
        // terminal in a white app" seam `neutralizeVibrancy` closes.
        if let contentView = window.contentView {
            neutralizeVibrancy(in: contentView)
        }
        // AppKit can (re)create these layers at any point after setup, not
        // just briefly after — `VibrancyGuardian` KVO-observes the subview
        // tree so every insertion gets neutralized immediately.
        VibrancyGuardian.install(on: window)
    }
}

/// Watches a window's view hierarchy for newly inserted subviews via KVO,
/// instead of guessing when AppKit finished creating the sidebar's chrome.
/// One guardian per window (idempotent); tears itself down on window close.
@MainActor
private final class VibrancyGuardian: NSObject {
    private static var associatedKey: UInt8 = 0

    private weak var window: NSWindow?
    private var observedViews: [ObjectIdentifier: NSView] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    static func install(on window: NSWindow) {
        if objc_getAssociatedObject(window, &associatedKey) is VibrancyGuardian {
            return
        }
        let guardian = VibrancyGuardian(window: window)
        objc_setAssociatedObject(window, &associatedKey, guardian, .OBJC_ASSOCIATION_RETAIN)
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()

        if let contentView = window.contentView {
            observeSubtree(contentView)
        }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            // Deliberately not `didUpdateNotification`: it fires every event-loop
            // cycle, and each rescan walks the whole tree — continuous overhead
            // against a constantly redrawing terminal. `subviews` KVO already catches every insertion.
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rescan() }
                }
            )
        }
        notificationTokens.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tearDown() }
            }
        )
    }

    private func rescan() {
        guard let contentView = window?.contentView else { return }
        neutralizeVibrancy(in: contentView)
        observeSubtree(contentView)
    }

    private func observeSubtree(_ view: NSView) {
        let id = ObjectIdentifier(view)
        if observedViews[id] == nil {
            observedViews[id] = view
            view.addObserver(self, forKeyPath: "subviews", options: [], context: nil)
        }
        for subview in view.subviews {
            observeSubtree(subview)
        }
    }

    // KVO delivers synchronously on whatever thread mutated `subviews`, always the main thread here.
    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "subviews", let view = object as? NSView else { return }
        MainActor.assumeIsolated {
            neutralizeVibrancy(in: view)
            observeSubtree(view)
        }
    }

    private func tearDown() {
        removeAllObservers()
        if let window {
            objc_setAssociatedObject(window, &Self.associatedKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private func removeAllObservers() {
        for view in observedViews.values {
            view.removeObserver(self, forKeyPath: "subviews")
        }
        observedViews.removeAll()

        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    // Not every window gets a full `close()` (offscreen test windows are
    // often just released), so `willCloseNotification` isn't guaranteed. KVO
    // requires every observer removed before the observed object deallocates, or its deinit crashes.
    deinit {
        MainActor.assumeIsolated { removeAllObservers() }
    }
}

@MainActor
private func neutralizeVibrancy(in view: NSView) {
    if let effectView = view as? NSVisualEffectView {
        effectView.state = .active
        effectView.material = .contentBackground
    }

    // The "Liquid Glass" sidebar's translucent backing is a private
    // `BackdropView` with no public retint API and no opaque material to
    // switch to — a purely decorative leaf, sibling to this app's SwiftUI
    // content, so hiding it is safe. `NSContainerConcentricGlassEffectView`
    // is deliberately not matched: it's the actual container hosting the sidebar's real content.
    let className = NSStringFromClass(type(of: view))
    if className.hasSuffix("BackdropView") {
        view.isHidden = true
    }

    for subview in view.subviews {
        neutralizeVibrancy(in: subview)
    }
}

extension View {
    /// Re-applies on every body update, so a theme change takes effect without restarting the app.
    func themedWindow(_ palette: BSidePalette) -> some View {
        modifier(ThemedWindowModifier(palette: palette))
    }
}

/// SwiftUI has no direct window accessor; places an invisible `NSView` and reads `.window` once attached.
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
