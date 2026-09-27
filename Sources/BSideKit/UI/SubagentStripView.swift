import SwiftUI

/// The subagent card strip: a real in-memory Ghostty surface
/// (`SubagentStripHost`) drawing `SubagentStripRenderer`'s box-drawing cards
/// above a task's terminal. Reserves its own fixed height, never an overlay.
///
/// Ticks its own render loop at ~10fps while any run is active, stopping once every run has settled.
struct SubagentStripView: View {
    var runs: [ChildRun]
    var viewedChildId: String?
    var onSelect: (SubagentStripMouseParser.HitTestResult) -> Void
    /// Called for every press on the strip, hit or not — see `TaskTerminalAreaView.focusShownSurface`.
    var onAnyClick: () -> Void

    // `@StateObject`, not `@State`: the frame height below depends on
    // `host`'s own `@Published latestViewport`, which a plain `@State`
    // wrapping a class wouldn't subscribe to, so the view would never
    // re-layout once real cell metrics arrive after the fallback estimate.
    @StateObject private var host = SubagentStripHost()

    // `onHostInput` and the render-loop `Task` are long-lived closures
    // outliving any single `body` evaluation; reading `self`'s properties
    // inside them would freeze on stale data (Pi sends `begin` before
    // `spawn`, so a frozen click handler would never see later panes).
    // `live` is a reference type refreshed every `body` evaluation instead.
    @State private var live = LiveStripState()
    @State private var didEnableMouseReporting = false

    private var isAnyRunActive: Bool {
        runs.contains { $0.state == .active || $0.state == .blocked }
    }

    var body: some View {
        live.runs = runs
        live.viewedChildId = viewedChildId
        live.onSelect = onSelect
        live.onAnyClick = onAnyClick

        return TerminalHostView(host: host.hostView)
            // +1 row of headroom: Ghostty floors `heightPixels / cellHeightPixels`,
            // so an exact height can round down and scroll the top border off screen; a blank trailing row is harmless.
            .frame(height: host.pointHeight(forRows: SubagentStripRenderer.totalRowCount + 1))
            .onAppear {
                let live = live
                host.onHostInput = { data in
                    for event in SubagentStripMouseParser.parse(data) where event.isPress {
                        if let hit = SubagentStripMouseParser.hitTest(column: event.column, row: event.row, result: live.lastResult) {
                            live.onSelect?(hit)
                        }
                        live.onAnyClick?()
                    }
                }
                if !didEnableMouseReporting {
                    host.enableMouseReporting()
                    didEnableMouseReporting = true
                }
                renderNow()
                startTicking()
            }
            .onDisappear { live.stopTicking() }
            .onChange(of: runs) { _, _ in renderNow() }
            .onChange(of: viewedChildId) { _, _ in renderNow() }
            .onChange(of: host.columns) { _, _ in renderNow() }
            .onChange(of: isAnyRunActive) { _, active in
                if active { startTicking() }
            }
    }

    private func startTicking() {
        let live = live
        let host = host
        live.startTicking {
            let columns = host.columns > 0 ? host.columns : SubagentStripRenderer.minCardWidth
            let result = SubagentStripRenderer.render(runs: live.runs, viewedChildId: live.viewedChildId, columns: columns, now: Date())
            live.lastResult = result
            host.render(lines: result.lines)
        }
    }

    private func renderNow() {
        // Bootstrap width before the surface reports metrics (`host.columns == 0`);
        // `SubagentStripRenderer.render` clamps itself if the real width is still under minimum.
        let columns = host.columns > 0 ? host.columns : SubagentStripRenderer.minCardWidth
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: viewedChildId, columns: columns, now: Date())
        live.lastResult = result
        host.render(lines: result.lines)
    }
}

/// Mutable, reference-type mirror of `SubagentStripView`'s per-render state
/// so long-lived closures always read the latest values (see `live`). Also
/// owns the ~10fps render ticker, stopped once no run is active.
@MainActor
final class LiveStripState {
    var runs: [ChildRun] = []
    var viewedChildId: String?
    var onSelect: ((SubagentStripMouseParser.HitTestResult) -> Void)?
    var onAnyClick: (() -> Void)?
    var lastResult = SubagentStripRenderer.Result(lines: [], slots: [], mainHintRange: nil)

    private var tickTask: Task<Void, Never>?

    var isAnyRunActive: Bool {
        runs.contains { $0.state == .active || $0.state == .blocked }
    }

    func startTicking(interval: Duration = .milliseconds(100), _ render: @escaping () -> Void) {
        tickTask?.cancel()
        guard isAnyRunActive else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                render()
                if !self.isAnyRunActive { return }
            }
        }
    }

    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
