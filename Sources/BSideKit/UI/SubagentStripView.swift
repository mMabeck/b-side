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

    @State private var host = SubagentStripHost()
    @State private var didEnableMouseReporting = false
    @State private var lastResult = SubagentStripRenderer.Result(lines: [], slots: [], mainHintRange: nil)
    @State private var tickTask: Task<Void, Never>?

    private var isAnyRunActive: Bool {
        runs.contains { $0.state == .active || $0.state == .blocked }
    }

    var body: some View {
        TerminalHostView(host: host.hostView)
            .frame(height: host.pointHeight(forRows: SubagentStripRenderer.totalRowCount))
            .onAppear {
                host.onHostInput = { data in
                    for event in SubagentStripMouseParser.parse(data) where event.isPress {
                        guard let hit = SubagentStripMouseParser.hitTest(column: event.column, row: event.row, result: lastResult) else { continue }
                        onSelect(hit)
                    }
                }
                if !didEnableMouseReporting {
                    host.enableMouseReporting()
                    didEnableMouseReporting = true
                }
                renderNow()
                startTicking()
            }
            .onDisappear { tickTask?.cancel() }
            .onChange(of: runs) { _, _ in renderNow() }
            .onChange(of: viewedChildId) { _, _ in renderNow() }
            .onChange(of: host.columns) { _, _ in renderNow() }
            .onChange(of: isAnyRunActive) { _, active in
                if active { startTicking() }
            }
    }

    private func startTicking() {
        tickTask?.cancel()
        guard isAnyRunActive else { return }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                renderNow()
                if !isAnyRunActive { return }
            }
        }
    }

    private func renderNow() {
        let columns = max(host.columns, SubagentStripRenderer.minCardWidth)
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: viewedChildId, columns: columns, now: Date())
        lastResult = result
        host.render(lines: result.lines)
    }
}
