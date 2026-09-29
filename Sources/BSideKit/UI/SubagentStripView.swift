import SwiftUI

struct SubagentStripView: View {
    var runs: [ChildRun]
    var viewedChildId: String?
    var onSelect: (SubagentStripMouseParser.HitTestResult) -> Void
    var onAnyClick: () -> Void

    // `@StateObject`: the frame height depends on `host`'s `@Published latestViewport`, which `@State` wouldn't observe.
    @StateObject private var host = SubagentStripHost()

    // Long-lived closures read `live`, a reference type refreshed every body, since captured `self` would go stale (Pi sends `begin` before `spawn`).
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
            // +1 row: Ghostty floors height/cellHeight, so an exact height can scroll the top border off screen.
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
        // Bootstrap width before the surface reports metrics.
        let columns = host.columns > 0 ? host.columns : SubagentStripRenderer.minCardWidth
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: viewedChildId, columns: columns, now: Date())
        live.lastResult = result
        host.render(lines: result.lines)
    }
}

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

    func startTicking(interval: Duration = .seconds(SubagentStripRenderer.spinnerFrameInterval), _ render: @escaping () -> Void) {
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
