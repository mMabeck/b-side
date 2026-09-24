import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("LiveStripState", .serialized)
struct LiveStripStateTests {
    private func makeRun(id: String, state: ChildRunState) -> ChildRun {
        var run = ChildRun(id: id, taskId: 1, agent: "explorer", taskLabel: "T")
        run.state = state
        return run
    }

    /// Polls `condition` until it's true or `timeout` elapses, instead of a
    /// fixed `Task.sleep` \u2014 the ticker's own poll interval is 100ms, but a
    /// heavily loaded test run can stall any single task far longer than
    /// that, so a fixed wait is inherently flaky here.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Starting the ticker while no run is active never schedules a render")
    func startTickingNoActiveRunsIsNoOp() async throws {
        let live = LiveStripState()
        live.runs = [makeRun(id: "a", state: .completed)]

        var callCount = 0
        live.startTicking { callCount += 1 }

        // No `Task` is even created in this case (see `LiveStripState.startTicking`'s
        // `guard`), so this is true immediately \u2014 no waiting needed.
        #expect(callCount == 0)
    }

    @Test("The ticker keeps calling render while a run is active")
    func tickerRendersWhileActive() async throws {
        let live = LiveStripState()
        live.runs = [makeRun(id: "a", state: .active)]

        var callCount = 0
        live.startTicking(interval: .milliseconds(1)) { callCount += 1 }

        await waitUntil { callCount >= 2 }
        live.stopTicking()
        #expect(callCount >= 2)
    }

    @Test("The ticker stops on its own once every run has settled")
    func tickerStopsOnceSettled() async throws {
        let live = LiveStripState()
        live.runs = [makeRun(id: "a", state: .active)]

        var callCount = 0
        live.startTicking(interval: .milliseconds(1)) {
            callCount += 1
            live.runs = [self.makeRun(id: "a", state: .completed)]
        }

        await waitUntil { !live.isAnyRunActive }
        let countAfterSettling = callCount
        // Give the loop every chance to tick again if it wrongly kept
        // going, then confirm it didn't.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(callCount == countAfterSettling)
    }

    @Test("stopTicking cancels an in-flight ticker")
    func stopTickingCancels() async throws {
        let live = LiveStripState()
        live.runs = [makeRun(id: "a", state: .active)]

        var callCount = 0
        live.startTicking(interval: .milliseconds(1)) { callCount += 1 }
        await waitUntil { callCount >= 1 }
        live.stopTicking()

        let countAfterStop = callCount
        try? await Task.sleep(for: .milliseconds(200))
        #expect(callCount == countAfterStop)
    }
}
