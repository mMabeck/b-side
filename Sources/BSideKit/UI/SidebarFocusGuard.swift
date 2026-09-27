import AppKit
import SwiftUI

/// Hands keyboard focus back to the visible task's terminal after any click
/// inside the sidebar. SwiftUI's `List` is backed by an `NSTableView`, which
/// makes itself first responder on mouse-down for its own row
/// tracking/selection before any `Button` action runs, with no public way
/// to opt out (`.focusable(false)` only affects SwiftUI's focus ring). This
/// lets the click land wherever AppKit wants, then reasserts terminal focus
/// one runloop hop later, the same imperative approach `MainAreaView.syncFocus()` uses.
///
/// Scoped to a marker `NSView` covering the sidebar's own bounds and that
/// view's own window, so clicks in other windows are never affected. Only
/// refocuses when `store.mainSelection` is actually a task.
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
            // No window yet on the same tick it's created; wait until attached, or `.window` below is always nil.
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

        /// Never swallows the event — returned unmodified by the caller.
        // Not `private` so `SidebarFocusGuardTests` can drive it with a programmatic `NSEvent`.
        func handleMouseDown(_ event: NSEvent, in window: NSWindow) {
            guard event.window === window, let markerView, markerView.window === window else { return }
            let locationInMarker = markerView.convert(event.locationInWindow, from: nil)
            guard markerView.bounds.contains(locationInMarker) else { return }
            // Deferred so this runs after AppKit's own mouse-down handling (row
            // selection, first responder, the row's action), or reasserting focus first would just be undone by it.
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
