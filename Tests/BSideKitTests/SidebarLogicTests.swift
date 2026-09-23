import Foundation
import SwiftUI
import Testing

@testable import BSideKit

@Suite("Sidebar pure logic")
struct SidebarLogicTests {
    // MARK: - Collapse-state persistence

    @Test("Collapse state round-trips through its RawRepresentable string")
    func collapseStateRoundTrips() {
        var state = SidebarCollapseState()
        state.setExpanded(false, for: 1)
        state.setExpanded(false, for: 42)
        state.setExpanded(true, for: 7) // never collapsed, shouldn't appear

        let roundTripped = SidebarCollapseState(rawValue: state.rawValue)
        #expect(roundTripped == state)
        #expect(roundTripped?.collapsedProjectIDs == [1, 42])
    }

    @Test("Empty collapse state round-trips to an empty string and back")
    func emptyCollapseStateRoundTrips() {
        let state = SidebarCollapseState()
        #expect(state.rawValue == "")
        #expect(SidebarCollapseState(rawValue: "") == state)
    }

    @Test("isExpanded defaults to true for an uncollapsed or nil project id")
    func isExpandedDefaultsTrue() {
        var state = SidebarCollapseState()
        #expect(state.isExpanded(1))
        #expect(state.isExpanded(nil))

        state.setExpanded(false, for: 1)
        #expect(!state.isExpanded(1))

        state.setExpanded(true, for: 1)
        #expect(state.isExpanded(1))
    }

    // MARK: - Status-to-colour mapping, all four states

    @Test("Each of the four task states maps to a distinct palette colour")
    func statusColorMappingCoversAllStates() {
        let palette = BSidePalette.fallback
        let colors: [TaskStatus: Color] = [
            .running: palette.statusRunning,
            .needsAttention: palette.statusNeedsAttention,
            .idle: palette.textDisabled,
            .finished: palette.statusSuccess,
        ]
        for (status, expected) in colors {
            #expect(status.color(in: palette) == expected)
        }
    }

    @Test("Status derivation prioritises merged, then attention, then activity, then idle")
    func statusDerivationPriority() {
        #expect(TaskStatus.derive(merged: true, isBlocked: true, isVanished: true, activeChildCount: 5) == .finished)
        #expect(TaskStatus.derive(merged: false, isBlocked: true, isVanished: false, activeChildCount: 3) == .needsAttention)
        #expect(TaskStatus.derive(merged: false, isBlocked: false, isVanished: true, activeChildCount: 0) == .needsAttention)
        #expect(TaskStatus.derive(merged: false, isBlocked: false, isVanished: false, activeChildCount: 1) == .running)
        #expect(TaskStatus.derive(merged: false, isBlocked: false, isVanished: false, activeChildCount: 0) == .idle)
    }

    @Test("A pending terminal question marks a task needing attention even with no other signal")
    func needsAttentionFromTerminalQuestion() {
        #expect(TaskStatus.derive(merged: false, isBlocked: false, isVanished: false, activeChildCount: 0, needsAttention: true) == .needsAttention)
        #expect(TaskStatus.derive(merged: true, isBlocked: false, isVanished: false, activeChildCount: 0, needsAttention: true) == .finished)
    }

    // MARK: - Branch-sync summary formatting

    @Test("Branch sync summary formatting")
    func branchSyncSummaryFormatting() {
        #expect(BranchSyncSummary.text(ahead: 0, behind: 0, merged: false) == nil)
        #expect(BranchSyncSummary.text(ahead: 3, behind: 0, merged: false) == "↑3")
        #expect(BranchSyncSummary.text(ahead: 0, behind: 2, merged: false) == "↓2")
        #expect(BranchSyncSummary.text(ahead: 1, behind: 4, merged: false) == "↑1 ↓4")
        #expect(BranchSyncSummary.text(ahead: 9, behind: 9, merged: true) == "merged")
    }

    @Test("Branch sync summary reads directly from BranchSyncStatus")
    func branchSyncSummaryFromStatus() {
        let status = TaskWorktreeService.BranchSyncStatus(ahead: 2, behind: 0, merged: false)
        #expect(BranchSyncSummary.text(for: status) == "↑2")
    }

    // MARK: - Reserved dot-column alignment invariant

    @Test("The status dot column reserves the same width regardless of status")
    func dotColumnWidthIsInvariant() {
        let widths: Set<CGFloat> = Set(
            ([nil] + TaskStatus.allCasesForTesting.map { $0 as TaskStatus? })
                .map(TaskRowLayout.dotColumnWidth(for:))
        )
        #expect(widths.count == 1)
        #expect(widths.first == TaskRowLayout.statusDotColumnWidth)
    }
}

private extension TaskStatus {
    static var allCasesForTesting: [TaskStatus] { [.running, .needsAttention, .idle, .finished] }
}
