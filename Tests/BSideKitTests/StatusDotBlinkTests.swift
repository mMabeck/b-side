import AppKit
import SwiftUI
import Testing

@testable import BSideKit

/// `StatusDot`'s blink is driven by `.onChange(of: shouldBlink, initial:
/// true)`, not `onAppear` alone, so a live status transition (e.g.
/// `.read` -> `.running` on the same task row) must start blinking without
/// remounting the view, and a transition back out of `.running` must reset
/// to full opacity rather than leaving it dimmed. This hosts a real
/// `StatusDot` offscreen and samples its rendered brightness over time
/// instead of sleeping a fixed duration for either assertion.
@MainActor
struct StatusDotBlinkTests {
    @Test(
        "StatusDot starts blinking when status changes to running, and settles back to full opacity when it changes back",
        .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    )
    func blinksOnLiveStatusChangeAndSettlesWhenReverted() async throws {
        let palette = BSidePalette.fallback
        let controller = StatusDotController(status: .read)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: StatusDotHarness(controller: controller, palette: palette)
                .environment(\.statusDotReduceMotion, false)
                .frame(width: 40, height: 40)
                .background(Color.black)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        window.contentView = hostingView
        window.setIsVisible(true)
        defer { window.orderOut(nil) }

        func sampleBrightness() -> CGFloat? {
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            hostingView.displayIgnoringOpacity(hostingView.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) else { return nil }
            return color.brightnessComponent
        }

        // Sanity: at rest on `.read`, the dot is fully opaque.
        let restingBrightness = try #require(await pollUntil(timeout: 2) { sampleBrightness() })

        controller.status = .running

        var observedDip = false
        // Generous: parallel snapshot suites can starve the main thread.
        let dipDeadline = Date().addingTimeInterval(10)
        while Date() < dipDeadline {
            try await Task.sleep(for: .milliseconds(40))
            guard let brightness = sampleBrightness() else { continue }
            // The blink eases toward 30% opacity on a black background, so a
            // dimmed sample reads meaningfully darker than the resting frame.
            if brightness < restingBrightness * 0.85 {
                observedDip = true
                break
            }
        }
        #expect(observedDip, "Expected StatusDot to dim while blinking as .running")

        controller.status = .read

        var settledBrightness: CGFloat?
        var stableStreak = 0
        let settleDeadline = Date().addingTimeInterval(10)
        while Date() < settleDeadline {
            try await Task.sleep(for: .milliseconds(40))
            guard let brightness = sampleBrightness() else { continue }
            if abs(brightness - restingBrightness) < 0.02 {
                stableStreak += 1
                if stableStreak >= 4 {
                    settledBrightness = brightness
                    break
                }
            } else {
                stableStreak = 0
            }
        }

        #expect(settledBrightness != nil, "Expected StatusDot to reset to full opacity after leaving .running")
    }
}

/// Polls `sample` until it returns a non-nil value or `timeout` elapses.
@MainActor
private func pollUntil<T>(timeout: TimeInterval, sample: () -> T?) async throws -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = sample() { return value }
        try await Task.sleep(for: .milliseconds(20))
    }
    return sample()
}

@MainActor
private final class StatusDotController: ObservableObject {
    @Published var status: TaskStatus
    init(status: TaskStatus) { self.status = status }
}

private struct StatusDotHarness: View {
    @ObservedObject var controller: StatusDotController
    let palette: BSidePalette

    var body: some View {
        StatusDot(status: controller.status, palette: palette)
    }
}
