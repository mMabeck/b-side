import AppKit
import SwiftUI

/// Hands keyboard focus back to the visible task's terminal after any click
/// inside the sidebar, so the user can click a task row, an "Active" row, a
/// project header, the "+" affordances, or empty list space without losing
/// the ability to keep typing into the terminal they were just in.
///
/// SwiftUI's `List` on macOS is backed by an `NSTableView`, which makes
/// itself the window's first responder on mouse-down as part of its own row
/// tracking/selection — before any `Button` action inside a row cell even
/// runs, and regardless of whether the click landed on a row at all. There
/// is no public way to opt a `List` out of that (`.focusable(false)` only
/// affects the SwiftUI focus-ring system, not AppKit's first-responder
/// hand-off on mouse-down), so this instead lets the click land wherever
/// AppKit wants, then reasserts the terminal's focus one runloop hop later
/// \u2014 the same "explicit, imperative focus" approach `MainAreaView.syncFocus()`
/// and `TerminalSurfaceHost.focus()`/`resignFocus()` already use for
/// terminal surfaces (see `GhosttyBridge.swift`'s `TerminalHostView` doc
/// comment for why a `@FocusState` bridge is unreliable here instead).
///
/// Scoped to a marker `NSView` placed as this sidebar's own background
/// (so it exactly covers the sidebar's bounds, resized by SwiftUI like any
/// other background view) and to mouse-downs in that view's own window, so
/// clicks in other windows \u2014 sheets, alerts, Settings, an offscreen test
/// window \u2014 are never affected. Only refocuses the terminal when
/// `store.mainSelection` is actually a task \u2014 a project dashboard or no
/// selection has no terminal to hand focus back to, so this leaves focus
/// alone in that case, matching `MainAreaView.syncFocus()`'s own guard.
struct SidebarFocusGuard: NSViewRepresentable {
    var store: ProjectsStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.store = store
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        var store: ProjectsStore
        private weak var markerView: NSView?
        private var monitor: Any?

        init(store: ProjectsStore) {
            self.store = store
        }

        func attach(to view: NSView) {
            markerView = view
            // The view has no window yet on the same tick it's created;
            // installing the monitor has to wait until it's actually
            // attached, or `markerView.window` below is always nil.
            DispatchQueue.main.async { [weak self] in
                self?.installMonitorIfNeeded()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, let window = markerView?.window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event, in: window)
                return event
            }
        }

        /// Never swallows the event \u2014 returned unmodified from the monitor's
        /// closure above \u2014 this only observes clicks that land within the
        /// sidebar's own bounds, then reasserts terminal focus afterwards.
        // Not `private` so `SidebarFocusGuardTests` can drive it directly
        // with a programmatically constructed `NSEvent`, instead of relying
        // on a real OS-level synthetic click.
        func handleMouseDown(_ event: NSEvent, in window: NSWindow) {
            guard event.window === window, let markerView, markerView.window === window else { return }
            let locationInMarker = markerView.convert(event.locationInWindow, from: nil)
            guard markerView.bounds.contains(locationInMarker) else { return }
            // Deferred so this runs after AppKit's own mouse-down handling
            // (row selection, the table view taking first responder, the
            // row's `Button` action) has already happened \u2014 reasserting
            // focus first would just be immediately undone by it.
            DispatchQueue.main.async { [weak self] in
                guard let self, case .task = self.store.mainSelection else { return }
                self.store.requestTerminalFocus()
            }
        }

        func tearDown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
