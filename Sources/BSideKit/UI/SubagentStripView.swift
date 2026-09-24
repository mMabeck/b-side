import SwiftUI

/// The subagent card strip: a real in-memory Ghostty surface
/// (`SubagentStripHost`) rendered above a task's main
/// terminal, drawing `SubagentStripRenderer`'s box-drawing cards. Reserves
/// its own fixed height so the terminal below it is simply shorter — never
/// an overlay.
///
/// Ticks its own render loop at ~10fps while any run is active (for the
/// spinner and the elapsed clocks), and stops ticking once every run in the
/// batch has settled (blocked/completed/failed), since a static status row
/// never needs another frame until something changes again.
struct SubagentStripView: View {
    var runs: [ChildRun]
    var viewedChildId: String?
    var onSelect: (SubagentStripMouseParser.HitTestResult) -> Void
    /// Called for every press on the strip, hit or not — see
    /// `TaskTerminalAreaView.focusShownSurface`'s doc comment for why.
    var onAnyClick: () -> Void

    // `@StateObject`, not `@State`: the frame height below reads
    // `host.pointHeight(forRows:)`, which depends on `host`'s own
    // `@Published latestViewport` — a plain `@State` wrapping a class
    // doesn't subscribe to that class's own publisher, so the view would
    // never re-layout once the surface's real cell metrics arrive after
    // the fallback estimate used for the very first frame.
    @StateObject private var host = SubagentStripHost()

    // Both `onHostInput` (installed once in `onAppear`) and the render-loop
    // `Task` below (started once per active stretch, but running across
    // many renders) are long-lived closures that outlive any single `body`
    // evaluation. Reading `runs`/`viewedChildId`/`onSelect` off `self`
    // inside them would freeze on whatever this `SubagentStripView` value
    // looked like when the closure was created — stale data forever after
    // (Pi sends `begin` before `spawn`, so a click handler frozen at the
    // first render never sees the panes that arrive moments later). `live`
    // is a reference type refreshed on every `body` evaluation, so anything
    // long-lived reads through it instead and always sees the latest state.
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
            // +1 row of headroom: Ghostty derives its own row count from
            // this height by flooring `heightPixels / cellHeightPixels`,
            // so an exact `totalRowCount`-row height can round down to one
            // row short and scroll the strip's top border off screen the
            // moment the last line is written. A blank trailing row is
            // harmless; a missing top border is not.
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
        // Not `max(host.columns, minCardWidth)`: forcing the width up to
        // the minimum card width when the surface is narrower than that
        // produced lines wider than the surface's real column count, which
        // Ghostty then wrapped across an extra row. `minCardWidth` here is
        // only a bootstrap default for the brief window before the surface
        // has reported any metrics at all (`host.columns == 0`); once it
        // has, `SubagentStripRenderer.render` clamps card rendering itself
        // when the real width is still under the minimum.
        let columns = host.columns > 0 ? host.columns : SubagentStripRenderer.minCardWidth
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: viewedChildId, columns: columns, now: Date())
        live.lastResult = result
        host.render(lines: result.lines)
    }
}

/// Mutable, reference-type mirror of `SubagentStripView`'s per-render
/// parameters (`runs`, `viewedChildId`, `onSelect`) plus the last rendered
/// hit-test geometry, refreshed on every `body` evaluation — see the
/// `live` property's doc comment on why long-lived closures read through
/// this instead of the view struct directly. Also owns the ~10fps render
/// ticker: started while some run is active, stopped once none are, so a
/// settled strip never redraws (and never keeps a `Task` alive) until
/// something changes again.
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
