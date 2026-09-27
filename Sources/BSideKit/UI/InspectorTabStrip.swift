import AppKit
import SwiftUI

/// Wraps `NSSegmentedControl` directly, since neither SwiftUI option can
/// draw both a segment's title and image on this SDK (verified by offscreen
/// pixel capture): `Picker(.segmented)` renders one or the other and hugs a
/// small centred pill; `TabView`'s tab strip drops images entirely.
struct InspectorTabStrip<Tab: Hashable>: NSViewRepresentable {
    struct Item {
        let tab: Tab
        let title: String
        let systemImage: String
    }

    let items: [Item]
    @Binding var selection: Tab
    /// Matches the app's chrome rather than the system's default blue.
    let accent: Color

    func makeNSView(context: Context) -> NSSegmentedControl {
        makeControl(target: context.coordinator, action: #selector(Coordinator.selectionChanged(_:)))
    }

    /// Split out of ``makeNSView(context:)`` so tests can assert on a real,
    /// configured control without an `NSViewRepresentableContext`, which can't be constructed outside SwiftUI.
    func makeControl(target: AnyObject?, action: Selector?) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        // Lets the control span the sidebar instead of shrink-wrapping its labels.
        control.segmentDistribution = .fillEqually
        control.segmentCount = items.count
        control.target = target
        control.action = action
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        configure(control)
    }

    private func configure(_ control: NSSegmentedControl) {
        for (index, item) in items.enumerated() {
            control.setLabel(item.title, forSegment: index)
            control.setImage(
                NSImage(systemSymbolName: item.systemImage, accessibilityDescription: item.title),
                forSegment: index
            )
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip(item.title, forSegment: index)
        }
        control.selectedSegment = items.firstIndex { $0.tab == selection } ?? 0
        control.selectedSegmentBezelColor = NSColor(accent)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: InspectorTabStrip

        init(parent: InspectorTabStrip) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.items.indices.contains(index) else { return }
            parent.selection = parent.items[index].tab
        }
    }
}
