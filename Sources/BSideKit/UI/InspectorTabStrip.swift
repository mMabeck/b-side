import AppKit
import SwiftUI

/// The right inspector's tab strip: one full-width, top-flush row of
/// segments, each showing an SF Symbol *and* its title.
///
/// This wraps `NSSegmentedControl` directly instead of using a SwiftUI
/// control, because neither SwiftUI option can draw both halves of a segment
/// on this SDK — verified by offscreen pixel capture, not by assumption:
///
/// - `Picker(.segmented)` renders a segment's title **or** its image, never
///   both. `Label(_:systemImage:)`, an inline `Text("\(Image(systemName:))…")`
///   and a bare `Image` all collapse to text-only or icon-only. It also hugs
///   its content into a small centred pill rather than spanning the sidebar.
/// - `TabView`'s own tab strip drops `tabItem` images entirely and draws
///   titles only.
///
/// AppKit's segmented control has had per-segment image + label since 10.0,
/// so dropping one level down is what actually buys the icons. Everything
/// else stays native: this is the same control SwiftUI would have used, just
/// configured directly.
struct InspectorTabStrip<Tab: Hashable>: NSViewRepresentable {
    struct Item {
        let tab: Tab
        let title: String
        let systemImage: String
    }

    let items: [Item]
    @Binding var selection: Tab
    /// Tints the selected segment's bezel with the theme's accent, matching
    /// the rest of the app's chrome rather than the system's default blue.
    let accent: Color

    func makeNSView(context: Context) -> NSSegmentedControl {
        makeControl(target: context.coordinator, action: #selector(Coordinator.selectionChanged(_:)))
    }

    /// Builds and fully configures the control. Split out of
    /// ``makeNSView(context:)`` so tests can assert on a real, configured
    /// `NSSegmentedControl` — an `NSViewRepresentableContext` cannot be
    /// constructed outside SwiftUI, so a test could otherwise never reach
    /// this configuration at all.
    func makeControl(target: AnyObject?, action: Selector?) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        // Equal-width segments are what let the control span the sidebar
        // instead of shrink-wrapping its labels.
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
            // Icon left of the title, rather than the default overlap that
            // makes the image win and the label vanish.
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
