import AppKit
import ObjectiveC
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
        // Applied at the `NSApp` level, not just this window: menus, popovers,
        // and sheets/alerts spawned from *any* window (including ones this
        // modifier is never attached to) resolve their own appearance from
        // `NSApp.effectiveAppearance` when they have none of their own, so
        // this is what keeps them from staying stuck in light `aqua`.
        NSApplication.shared.appearance = palette.preferredAppearance
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
        // AppKit can create or recreate the sidebar's vibrancy/backdrop layers
        // at any point after this window is set up (confirmed under load: it
        // is not bounded to a short window after creation), so a fixed
        // schedule of retries races the view hierarchy instead of tracking
        // it. `VibrancyGuardian` KVO-observes the subview tree so every
        // insertion — whenever it happens — gets neutralized immediately,
        // and also re-scans on the window notifications that tend to
        // accompany chrome changes, as a cheap belt-and-suspenders measure.
        VibrancyGuardian.install(on: window)
    }
}

/// Watches a window's view hierarchy for newly inserted subviews (via KVO on
/// `subviews`) and neutralizes vibrancy on each one as it appears, instead of
/// guessing when AppKit might have finished creating the sidebar's chrome.
/// One guardian is installed per window (idempotent — re-`apply`ing on the
/// same window is a no-op beyond a single immediate re-neutralize pass) and
/// tears itself down, removing all KVO and notification observers, when the
/// window closes.
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
            // Deliberately not `didUpdateNotification`: it fires about once
            // per event-loop cycle for the window, and each rescan walks the
            // whole view tree and re-registers KVO — continuous overhead in
            // an app whose main content is a constantly redrawing terminal.
            // The `subviews` KVO below already catches every insertion,
            // which is the event that actually matters here.
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

    // KVO delivers this synchronously on whatever thread mutated `subviews`,
    // which for this app's own window/view hierarchy is always the main
    // thread — `assumeIsolated` documents that instead of hopping queues.
    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "subviews", let view = object as? NSView else { return }
        MainActor.assumeIsolated {
            // The `NSVisualEffectView` and private `BackdropView` chrome
            // both arrive as newly inserted subviews.
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

    // Not every caller runs a window through a full `close()` (offscreen
    // test windows in particular are often just released), so
    // `willCloseNotification` is not a guarantee. KVO requires every
    // observer to be removed before its observed object deallocates, or the
    // observed object's own deinit crashes — so this is a hard safety net,
    // not just tidiness. `deinit` on a `@MainActor` class runs nonisolated,
    // but the object is uniquely referenced by this point (nothing else can
    // race a mutation), so touching its stored state directly here is safe.
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
