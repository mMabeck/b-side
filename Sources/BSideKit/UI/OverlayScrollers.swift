import AppKit
import SwiftUI

extension View {
    /// Scroll bars that appear while scrolling and fade out, even when a mouse
    /// makes macOS's "Automatic" setting fall back to always-visible ones.
    /// Apply to a `List` or `ScrollView`; SwiftUI exposes no scroller style.
    func overlayScrollers() -> some View {
        background(OverlayScrollerAccessor())
    }
}

private struct OverlayScrollerAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init() {
            // AppKit rewrites every scroll view's style when the preferred one
            // changes (e.g. a mouse is plugged in), so re-apply afterwards.
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func apply() {
            if scrollView?.window == nil, let anchor { scrollView = Self.scrollView(behind: anchor) }
            guard let scrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }

        /// The background anchor is a sibling of the scroll view it backs, so
        /// search outward for the nearest scroll view covering the anchor.
        private static func scrollView(behind anchor: NSView) -> NSScrollView? {
            guard anchor.window != nil else { return nil }
            let anchorFrame = anchor.convert(anchor.bounds, to: nil)
            let center = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
            var ancestor = anchor.superview
            while let current = ancestor {
                if let match = firstScrollView(in: current, containing: center) { return match }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstScrollView(in root: NSView, containing point: CGPoint) -> NSScrollView? {
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let scrollView = view as? NSScrollView,
                   scrollView.convert(scrollView.bounds, to: nil).contains(point) {
                    return scrollView
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
