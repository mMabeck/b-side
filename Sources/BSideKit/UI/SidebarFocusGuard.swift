import AppKit
import SwiftUI

/// NSTableView takes first responder on mouse-down with no way to opt out; refocus the terminal one runloop hop later.
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

        func handleMouseDown(_ event: NSEvent, in window: NSWindow) {
            guard event.window === window, let markerView, markerView.window === window else { return }
            let locationInMarker = markerView.convert(event.locationInWindow, from: nil)
            guard markerView.bounds.contains(locationInMarker) else { return }
            // Deferred until after AppKit's mouse-down handling, or refocusing would be undone.
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
