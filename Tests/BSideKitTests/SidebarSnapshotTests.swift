import AppKit
import Foundation
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders the left sidebar offscreen, populated with two projects (one
/// collapsed, one expanded with tasks in different states), and samples real
/// pixels inside the sidebar region. No layers are hidden before sampling:
/// this is the check the previous snapshot test skipped by excluding the
/// system's translucent chrome from the measurement (see
/// `ContentViewThemeSnapshotTests`). A real, never-key, never-onscreen
/// `NSWindow` driven only by programmatic APIs — no synthetic clicks or
/// keystrokes.
@MainActor
struct SidebarSnapshotTests {
    @Test("The populated sidebar samples as the palette's opaque surface colour, not system chrome")
    func sidebarIsOpaquelyThemed() async throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-sidebar-test-\(UUID().uuidString)")
        let ghosttyConfigDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)
        try "theme = Ayu Mirage\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previousXDG {
                setenv("XDG_CONFIG_HOME", previousXDG, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            try? FileManager.default.removeItem(at: configHome)
        }

        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        let expectedPalette = BSidePalette.themed(from: ayuMirage)
        let expectedSurface = NSColor(expectedPalette.surfaceBackground)

        UserDefaults.standard.set(false, forKey: "leftSidebarCollapsed")
        UserDefaults.standard.set(true, forKey: "rightSidebarCollapsed")
        UserDefaults.standard.set(true, forKey: "terminalDrawerCollapsed")

        let workDir = configHome.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: workDir)
        try await runGit(["config", "user.email", "test@example.com"], in: workDir)
        try await runGit(["config", "user.name", "Test"], in: workDir)
        try "hello".write(to: workDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(["add", "."], in: workDir)
        try await runGit(["commit", "-m", "initial"], in: workDir)
        try await runGit(["branch", "feature/merged"], in: workDir) // == HEAD, trivially merged
        try "more".write(to: workDir.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try await runGit(["checkout", "-b", "feature/ahead"], in: workDir)
        try await runGit(["add", "."], in: workDir)
        try await runGit(["commit", "-m", "ahead"], in: workDir)
        try await runGit(["checkout", "main"], in: workDir)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let collapsedWorkDir = configHome.appendingPathComponent("other-repo")
        try FileManager.default.createDirectory(at: collapsedWorkDir, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: collapsedWorkDir)

        let expandedProject = Project(path: workDir.path, displayName: "bside", baseRef: "main")
        let collapsedProject = Project(path: collapsedWorkDir.path, displayName: "dotfiles", baseRef: "main")

        let ids: (expandedProjectID: Int64, collapsedProjectID: Int64, finishedTaskID: Int64, attentionTaskID: Int64, runningTaskID: Int64, idleTaskID: Int64) = try await database.dbQueue.write { db in
            var expanded = expandedProject
            try expanded.insert(db)
            let expandedProjectID = expanded.id!

            var collapsed = collapsedProject
            try collapsed.insert(db)
            let collapsedProjectID = collapsed.id!

            var finished = TaskRecord(
                projectId: expandedProjectID, name: "Ship the release", branchName: "feature/merged",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try finished.insert(db)

            var attention = TaskRecord(
                projectId: expandedProjectID, name: "Fix the login bug", branchName: "feature/ahead",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try attention.insert(db)

            var running = TaskRecord(
                projectId: expandedProjectID, name: "Refactor the parser", branchName: "feature/ahead",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try running.insert(db)

            var idle = TaskRecord(
                projectId: expandedProjectID, name: "Write docs", branchName: "main",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try idle.insert(db)

            var collapsedTask = TaskRecord(
                projectId: collapsedProjectID, name: "Hidden while collapsed", branchName: "main",
                worktreePath: collapsedWorkDir.path, harness: "claude", permissionLevel: "default"
            )
            try collapsedTask.insert(db)

            return (expandedProjectID, collapsedProjectID, finished.id!, attention.id!, running.id!, idle.id!)
        }
        let expandedProjectID = ids.expandedProjectID
        let collapsedProjectID = ids.collapsedProjectID
        let finishedTaskID = ids.finishedTaskID
        let attentionTaskID = ids.attentionTaskID
        let runningTaskID = ids.runningTaskID
        let idleTaskID = ids.idleTaskID

        store.subagentFeed.beginRun(taskId: attentionTaskID, childId: "blocked-child", agent: "explorer", taskLabel: "Investigate")
        store.subagentFeed.ingest(
            taskId: attentionTaskID,
            childId: "blocked-child",
            event: .messageEnd(
                role: "assistant", stopReason: nil, errorMessage: nil,
                toolCalls: [SubagentToolCall(id: "t1", name: "question", arguments: [:])], text: nil
            )
        )
        store.subagentFeed.beginRun(taskId: runningTaskID, childId: "active-child", agent: "builder", taskLabel: "Working")

        UserDefaults.standard.set(
            SidebarCollapseState(collapsedProjectIDs: [collapsedProjectID]).rawValue,
            forKey: "sidebarCollapsedProjectIDs"
        )

        store.start()
        try await Task.sleep(for: .milliseconds(300))
        for taskID in [finishedTaskID, attentionTaskID, runningTaskID, idleTaskID] {
            let task = try #require(store.tasksByProject[expandedProjectID]?.first { $0.id == taskID })
            await store.refreshSyncStatus(for: task, project: expandedProject)
        }
        try await Task.sleep(for: .milliseconds(100))

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.setIsVisible(true)

        guard let contentView = window.contentView else {
            Issue.record("Window has no content view to render")
            return
        }

        func report(_ label: String, _ color: NSColor) -> String {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            return "\(label): r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent)"
        }
        let expected = expectedSurface.usingColorSpace(.deviceRGB) ?? expectedSurface

        func isCloseToThemedSurface(_ color: NSColor) -> Bool {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            // Genuinely opaque and themed means close to the palette's own
            // surface colour — not white, not an unrelated system grey.
            return abs(c.redComponent - expected.redComponent) < 0.2
                && abs(c.greenComponent - expected.greenComponent) < 0.2
                && abs(c.blueComponent - expected.blueComponent) < 0.2
        }

        func captureSidebarSamples() -> [NSColor] {
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            // Captured via `CGWindowListCreateImage`, not a manual `NSView`
            // draw pass: a manual `bitmapImageRepForCachingDisplay` +
            // `displayIgnoringOpacity` capture (as used by
            // `ContentViewThemeSnapshotTests`) only walks the `drawRect`-based
            // rendering path and silently produces a blank image for `List`'s
            // per-row `NSHostingView`s, which are only ever actually painted by
            // WindowServer's real compositor — confirmed by dumping the row view
            // hierarchy (frames and row counts were correct; the manual capture
            // still came back empty). Asking WindowServer directly for this
            // window's own composited pixels is the only capture path that
            // reflects what real rendering actually produced. The window is
            // still positioned off any physical display and never key/frontmost,
            // so nothing is shown to the user; no layers are hidden before
            // sampling — see `ContentViewThemeSnapshotTests`.
            let windowID = CGWindowID(window.windowNumber)
            guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
                Issue.record("Failed to capture window image")
                return []
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: URL(fileURLWithPath: "/tmp/bside-sidebar-legacy.png"))
            }

            let windowFrame = window.frame
            let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
            func sample(atPointX x: CGFloat, appKitY y: CGFloat) -> NSColor? {
                let pixelX = Int(x * scaleX)
                let pixelY = bitmap.pixelsHigh - Int(y * scaleY) - 1
                guard pixelX >= 0, pixelX < bitmap.pixelsWide, pixelY >= 0, pixelY < bitmap.pixelsHigh else { return nil }
                return bitmap.colorAt(x: pixelX, y: pixelY)
            }

            let contentFrame = contentView.frame
            // Sample multiple points down the sidebar column — between rows and
            // behind row content — so a themed background that's only partially
            // opaque (e.g. only under text) doesn't slip through.
            let sidebarSampleX = contentFrame.minX + 30
            let sampleYs: [CGFloat] = [0.15, 0.35, 0.55, 0.75, 0.92].map { contentFrame.minY + contentFrame.height * $0 }
            return sampleYs.compactMap { sample(atPointX: sidebarSampleX, appKitY: $0) }
        }

        // Poll instead of a single fixed sleep: the window's chrome
        // suppression (see `ThemedWindowModifier`) reacts to AppKit inserting
        // vibrancy/backdrop layers asynchronously and has no fixed completion
        // time, so waiting a guessed-at duration and sampling once is either
        // too short (flaky) or too long (slow) depending on machine load.
        // Instead, re-layout, re-display and re-sample until the sidebar
        // settles to the themed surface colour or a timeout elapses — the
        // timeout path falls through to the assertions below with whatever
        // was last sampled, so a genuine product regression still fails the
        // test rather than being waited out.
        var samples: [NSColor] = []
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            samples = captureSidebarSamples()
        } while (samples.count != 5 || !samples.allSatisfy(isCloseToThemedSurface)) && Date() < deadline

        window.orderOut(nil)

        #expect(samples.count == 5, "Failed to sample all sidebar probe points")
        print(([report("expectedSurface", expectedSurface)] + samples.enumerated().map { report("sidebar[\($0.offset)]", $0.element) }).joined(separator: " | "))

        for color in samples {
            #expect(isCloseToThemedSurface(color), "Sidebar pixel \(report("", color)) is not close to the themed surface colour \(report("", expectedSurface))")
        }
    }

    @Test("Status dots left-align with the project title and the ACTIVE header, and the old indent-guide hairline is gone")
    func statusDotsLeftAlignWithHeaders() async throws {
        let suiteName = "bside-sidebar-align-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        let palette = BSidePalette.themed(from: ayuMirage)
        GhosttyResolvedTheme.resolveEagerly()

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

        let project = Project(path: "/tmp/bside-align-project", displayName: "bside", baseRef: "main")

        let ids: (projectID: Int64, runningID: Int64, unreadID: Int64, readID: Int64, questionID: Int64, inactiveID: Int64) = try await database.dbQueue.write { db in
            var project = project
            try project.insert(db)
            let projectID = project.id!

            func makeTask(_ name: String) throws -> Int64 {
                var task = TaskRecord(
                    projectId: projectID, name: name, branchName: "main",
                    worktreePath: "/tmp/bside-align-project", harness: "claude", permissionLevel: "default"
                )
                try task.insert(db)
                return task.id!
            }

            let runningID = try makeTask("Running task")
            let unreadID = try makeTask("Unread task")
            let readID = try makeTask("Read task")
            let questionID = try makeTask("Question task")
            // Never opened or active, so it sorts below every bumped task.
            let inactiveID = try makeTask("Inactive task")

            return (projectID, runningID, unreadID, readID, questionID, inactiveID)
        }

        store.start()
        try await waitUntil { !store.projects.isEmpty }

        // Open four of the five tasks (all but `inactiveID`), driving each to
        // a distinct status: running (busy), unread (a busy\u2192idle
        // transition), read (open with nothing new), question (a bell).
        //
        // Each of these events also moves its task to the front of Active
        // and to the top of the project list (`bumpTaskActivity`), so the
        // order matters: the scan below needs Active to read running,
        // unread, read, question top-down, so the question task's terminal
        // is opened only after every bump. Its bell makes it the most
        // recently active task, so it's the topmost row under the project
        // header.
        store.noteTerminalOpened(taskID: ids.runningID)
        store.noteTerminalOpened(taskID: ids.unreadID)
        store.noteTerminalOpened(taskID: ids.readID)

        store.setTaskBusy(ids.unreadID)
        store.clearTaskBusy(ids.unreadID)
        store.setTaskBusy(ids.runningID)
        store.handleTerminalBell(taskID: ids.questionID)
        store.noteTerminalOpened(taskID: ids.questionID)
        #expect(store.openTerminalTaskIDs == [ids.runningID, ids.unreadID, ids.readID, ids.questionID])
        try await waitUntil { store.tasksByProject[ids.projectID]?.first?.id == ids.questionID }

        defaults.set(SidebarCollapseState().rawValue, forKey: "sidebarCollapsedProjectIDs")

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: SidebarView(store: store)
                .environment(\.statusDotReduceMotion, true) // freezes the running dot's blink for a deterministic capture
                .defaultAppStorage(defaults)
        )
        window.setIsVisible(true)

        guard let contentView = window.contentView else {
            Issue.record("Window has no content view to render")
            return
        }

        func captureBitmap() -> NSBitmapImageRep? {
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let windowID = CGWindowID(window.windowNumber)
            guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
                return nil
            }
            return NSBitmapImageRep(cgImage: cgImage)
        }

        func isClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.16) -> Bool {
            let ca = a.usingColorSpace(.deviceRGB) ?? a
            let cb = b.usingColorSpace(.deviceRGB) ?? b
            return abs(ca.redComponent - cb.redComponent) < tolerance
                && abs(ca.greenComponent - cb.greenComponent) < tolerance
                && abs(ca.blueComponent - cb.blueComponent) < tolerance
        }

        /// Topmost (at or below `minY`), then leftmost, pixel matching
        /// `target` — used to locate a status dot (each colour appears
        /// nowhere else in the sidebar) or a distinctively-coloured text run
        /// by colour alone rather than by a guessed row geometry.
        func firstMatch(_ bitmap: NSBitmapImageRep, target: NSColor, tolerance: CGFloat = 0.16, minY: Int = 0, maxX: Int? = nil) -> (x: Int, y: Int)? {
            let upperX = maxX ?? bitmap.pixelsWide
            for y in minY..<bitmap.pixelsHigh {
                for x in 0..<upperX {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    if isClose(color, target, tolerance: tolerance) {
                        return (x, y)
                    }
                }
            }
            return nil
        }

        /// The leftmost pixel matching `target` within `xRange` at device row
        /// `y`, scanning a small vertical band around it to tolerate the
        /// dot/text not landing on the exact sampled scanline.
        func leftmostMatch(_ bitmap: NSBitmapImageRep, target: NSColor, y: Int, xRange: Range<Int>, tolerance: CGFloat = 0.16, yBand: Int = 3) -> Int? {
            for dy in -yBand...yBand {
                let row = y + dy
                guard row >= 0, row < bitmap.pixelsHigh else { continue }
                for x in xRange {
                    guard let color = bitmap.colorAt(x: x, y: row) else { continue }
                    if isClose(color, target, tolerance: tolerance) {
                        return x
                    }
                }
            }
            return nil
        }

        // A shape's true left edge: `firstMatch`'s topmost-row scan can land
        // on a row near the top of a circle or glyph, where the visible arc
        // or stroke is narrower and further right than the shape's actual
        // left edge - so this re-scans a band of rows spanning the shape's
        // full height around that anchor and takes the minimum x seen, which
        // is the left edge regardless of which row the initial scan happened
        // to hit first.
        func leftEdge(_ bitmap: NSBitmapImageRep, target: NSColor, tolerance: CGFloat = 0.16, minY: Int = 0, maxX: Int? = nil, upBand: Int, downBand: Int) -> (x: Int, y: Int)? {
            guard let anchor = firstMatch(bitmap, target: target, tolerance: tolerance, minY: minY, maxX: maxX) else { return nil }
            var best = anchor
            for y in max(minY, anchor.y - upBand)...min(bitmap.pixelsHigh - 1, anchor.y + downBand) {
                guard let x = leftmostMatch(bitmap, target: target, y: y, xRange: 0..<(maxX ?? bitmap.pixelsWide), tolerance: tolerance, yBand: 0) else { continue }
                if x < best.x { best = (x, y) }
            }
            return best
        }

        func dotLeftEdge(_ bitmap: NSBitmapImageRep, target: NSColor, tolerance: CGFloat = 0.16, minY: Int = 0, maxX: Int? = nil, rowScale: CGFloat) -> (x: Int, y: Int)? {
            let band = Int(TaskRowLayout.statusDotDiameter * rowScale) + 2
            return leftEdge(bitmap, target: target, tolerance: tolerance, minY: minY, maxX: maxX, upBand: band, downBand: band)
        }

        // A themed sidebar's two text colours (`textPrimary`,
        // `textSecondary`) are close enough after antialiasing that
        // colour-matching one against the other is unreliable - a header's
        // own trailing antialiased pixels can pass a title's colour
        // tolerance and vice versa. Contrast against the surface background
        // instead is unambiguous (background is dark, every label colour is
        // light, or the reverse for a light theme), so a text row is found
        // by "not background" rather than by matching a specific label
        // colour.
        let backgroundNS = NSColor(palette.surfaceBackground)
        func isTextPixel(_ color: NSColor) -> Bool {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            let b = backgroundNS.usingColorSpace(.deviceRGB) ?? backgroundNS
            let diff = abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent) + abs(c.blueComponent - b.blueComponent)
            return diff > 0.3
        }
        func rowHasText(_ bitmap: NSBitmapImageRep, y: Int, maxX: Int) -> Bool {
            guard y >= 0, y < bitmap.pixelsHigh else { return false }
            for x in 0..<maxX {
                if let color = bitmap.colorAt(x: x, y: y), isTextPixel(color) { return true }
            }
            return false
        }

        /// The bounding box of the first contiguous run of text-coloured
        /// rows at or below `minY` and above `maxY`, scoped to `x < maxX` so
        /// a row's trailing icon/count doesn't get swept in - one line of
        /// text (a header or a title), isolated by vertical contrast against
        /// the background rather than by matching either label colour
        /// against the other. `maxY` matters as much as `minY`: without it,
        /// a small gap between two text lines (e.g. a header and the title
        /// right below it) reads as just another "transitional dip" and the
        /// scan silently swallows the next line's text into the same block -
        /// callers bound `maxY` using an unambiguous landmark (a status dot's
        /// colour) just below the line they actually want.
        func textBlock(_ bitmap: NSBitmapImageRep, minY: Int, maxY: Int, maxX: Int) -> (top: Int, bottom: Int, leftX: Int)? {
            var top: Int?
            var y = minY
            while y <= maxY {
                if rowHasText(bitmap, y: y, maxX: maxX) { top = y; break }
                y += 1
            }
            guard let top else { return nil }
            var bottom = top
            var consecutiveBlank = 0
            y = top + 1
            // A row transitional between two thick strokes (or two letters'
            // serifs) can occasionally dip under the contrast threshold
            // without the glyph actually having ended - tolerate a couple of
            // such rows rather than stopping the block early.
            while y <= maxY {
                if rowHasText(bitmap, y: y, maxX: maxX) {
                    bottom = y
                    consecutiveBlank = 0
                } else {
                    consecutiveBlank += 1
                    if consecutiveBlank > 2 { break }
                }
                y += 1
            }
            var leftX = maxX
            for row in top...bottom {
                for x in 0..<maxX {
                    if let color = bitmap.colorAt(x: x, y: row), isTextPixel(color) {
                        leftX = min(leftX, x)
                        break
                    }
                }
            }
            return (top, bottom, leftX)
        }

        var bitmap: NSBitmapImageRep?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            bitmap = captureBitmap()
        } while bitmap == nil && Date() < deadline

        // Give the two-phase (open terminals, then busy/idle/bell) state a
        // moment to settle into the sidebar before the final capture, and
        // re-capture once more so the image reflects it.
        try await Task.sleep(for: .milliseconds(200))
        bitmap = captureBitmap()

        window.orderOut(nil)

        guard let bitmap else {
            Issue.record("Failed to capture window image")
            return
        }
        if let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: "/tmp/bside-sidebar.png"))
        }

        let scaleX = CGFloat(bitmap.pixelsWide) / window.frame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / window.frame.height

        // "ACTIVE" is the first line the list content renders. Skips the
        // title bar / toolbar strip (traffic lights, the sidebar toggle
        // button) above it, where a light system icon can otherwise read as
        // a false match for this fairly light grey.
        // The running dot is the first (topmost) of the four Active rows.
        // Blue/green ("unread"/"read") are used for every other measurement
        // below because, empirically, this screenshot pipeline's colour
        // fidelity is loose enough that the warm hues (amber "running" vs
        // orange-red "question") aren't reliably distinguishable from one
        // another, while blue and green stay unambiguous.
        let runningDotPixel = dotLeftEdge(bitmap, target: NSColor(palette.statusRunning), rowScale: scaleY)
        // The dot's own topmost row (unadjusted for its left edge) bounds
        // the ACTIVE header's text block from below, so a small gap between
        // the header and the first Active row's own title/subtitle text
        // can't be mistaken for a mere transitional dip and swallow that
        // row's text into the header's block.
        let runningDotTopY = firstMatch(bitmap, target: NSColor(palette.statusRunning), minY: Int(40 * scaleY), maxX: Int(120 * scaleX))?.y
        let activeHeaderBlock = textBlock(bitmap, minY: Int(40 * scaleY), maxY: (runningDotTopY ?? bitmap.pixelsHigh) - 1, maxX: Int(120 * scaleX))
        let activeHeaderPixel = activeHeaderBlock.map { (x: $0.leftX, y: $0.top) }

        #expect(activeHeaderPixel != nil, "Could not find the ACTIVE header in the capture")
        #expect(runningDotPixel != nil, "Could not find the running status dot in the capture")

        // "PROJECTS" (textSecondary) is the first thing rendered after the
        // Active section's four rows, and the project title (textPrimary) is
        // the first thing rendered after that - locating both top-down from
        // a known floor (the last Active row) is more robust than guessing
        // how far above any particular task row the title sits. The
        // question dot's *topmost* occurrence (the last Active row) is only
        // used to find that floor, never compared against anything, so its
        // colour ambiguity doesn't matter here.
        // A tighter tolerance than dot-lookups elsewhere: at the default
        // 0.16 this colour and `statusRunning` (both warm, amber/orange-red
        // hues) are close enough, after this screenshot pipeline's own
        // colour-management, to collide - `firstMatch` would return the
        // Active section's *first* (running) row instead of its actual
        // fourth (question) row. At 0.10 they don't collide, and this real
        // question dot is still found reliably.
        let questionDotPixel = firstMatch(bitmap, target: NSColor(palette.statusNeedsAttention), tolerance: 0.10)
        var projectTitleX: Int?
        // The task dot to compare against the project title: the *second*
        // occurrence of the question dot's colour (the first, found above,
        // is its own Active-section row), on the task row directly under
        // the project header.
        var projectSectionTaskDotX: Int?
        if let questionDotPixel {
            // Found first (before the header/title text blocks below) so
            // both blocks can be bounded from below by this task row's own
            // dot - without that ceiling, the small gaps between "PROJECTS",
            // the project title, and the task row's own title read as mere
            // transitional dips and everything fuses into one block.
            let secondQuestionDotTopY = firstMatch(bitmap, target: NSColor(palette.statusNeedsAttention), tolerance: 0.10, minY: questionDotPixel.y + Int(30 * scaleY))?.y
            let sectionFloor = (secondQuestionDotTopY ?? bitmap.pixelsHigh) - 1
            // The last Active row (Question task) has its own subtitle line
            // (its project's folder name) directly below its dot, in the
            // same secondary colour as the "PROJECTS" header - so the first
            // text block below the dot is that subtitle, not the header.
            // Three text blocks follow the dot in order: the subtitle, the
            // "PROJECTS" header, then the project title.
            let subtitleBlock = textBlock(bitmap, minY: questionDotPixel.y + Int(4 * scaleY), maxY: sectionFloor, maxX: Int(150 * scaleX))
            if let subtitleBlock {
                let projectsHeaderBlock = textBlock(bitmap, minY: subtitleBlock.bottom + Int(2 * scaleY), maxY: sectionFloor, maxX: Int(120 * scaleX))
                if let projectsHeaderBlock {
                    let titleBlock = textBlock(bitmap, minY: projectsHeaderBlock.bottom + Int(2 * scaleY), maxY: sectionFloor, maxX: Int(150 * scaleX))
                    projectTitleX = titleBlock?.leftX
                }

                let secondQuestionDotPixel = dotLeftEdge(bitmap, target: NSColor(palette.statusNeedsAttention), tolerance: 0.10, minY: questionDotPixel.y + Int(30 * scaleY), rowScale: scaleY)
                projectSectionTaskDotX = secondQuestionDotPixel?.x
            }
        }
        #expect(projectTitleX != nil, "Could not find the project title below the PROJECTS header")
        #expect(projectSectionTaskDotX != nil, "Could not find a task dot below the project header")


        func points(_ px: Int, scale: CGFloat) -> CGFloat { CGFloat(px) / scale }

        if let activeHeaderPixel, let runningDotPixel {
            let headerX = points(activeHeaderPixel.x, scale: scaleX)
            let dotX = points(runningDotPixel.x, scale: scaleX)
            print("Measured alignment: ACTIVE header x=\(headerX)pt, Active-row running dot x=\(dotX)pt, delta=\(abs(headerX - dotX))pt")
            #expect(abs(headerX - dotX) <= 1, "Active-row dot (x=\(dotX)) should left-align with the ACTIVE header (x=\(headerX))")
        }

        if let projectSectionTaskDotX, let projectTitleX {
            let dotX = points(projectSectionTaskDotX, scale: scaleX)
            let titleX = points(projectTitleX, scale: scaleX)
            print("Measured alignment: project title x=\(titleX)pt, task dot x=\(dotX)pt, delta=\(abs(titleX - dotX))pt")
            #expect(abs(titleX - dotX) <= 1, "Task dot (x=\(dotX)) should left-align with the project title (x=\(titleX))")
        }

        // No stray 1pt hairline: the old per-row indent guide is gone, and
        // `.listRowSeparator(.hidden)` suppresses `List`'s own separators.
        // A themed sidebar has no reason to show the raw system separator
        // colour as a thin line inside a row's own content region (as
        // opposed to the deliberate 1pt footer divider above "Add Project",
        // which sits outside the `List` entirely).
        if let activeHeaderPixel, let runningDotPixel {
            // Scoped to the gap between the dot column and the task title
            // text (well inside the row's own content, clear of both the
            // window's own edge/chrome and the dot/text glyphs themselves)
            // and to the vertical span of the Active section's own rows.
            let separatorNS = NSColor(palette.separator)
            var strayHairlineColumn: Int?
            let scanXRange = Int(39 * scaleX)..<Int(41 * scaleX)
            let scanYRange = activeHeaderPixel.y..<min(bitmap.pixelsHigh, runningDotPixel.y + Int(220 * scaleY))
            // A genuine hairline (like the removed indent guide) is an
            // unbroken line down the whole row span; a stray antialiased
            // text/dot edge pixel that happens to land near the separator
            // colour is, at most, a few pixels tall. Requiring an almost
            // complete run across the scanned span tells the two apart.
            let hairlineRunThreshold = Int(Double(scanYRange.count) * 0.85)
            for x in scanXRange {
                var runLength = 0
                for y in scanYRange {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    if isClose(color, separatorNS, tolerance: 0.03) {
                        runLength += 1
                        if runLength > hairlineRunThreshold {
                            strayHairlineColumn = x
                            break
                        }
                    } else {
                        runLength = 0
                    }
                }
                if strayHairlineColumn != nil { break }
            }
            #expect(strayHairlineColumn == nil, "Found a stray separator-coloured hairline inside the task rows at device x=\(strayHairlineColumn ?? -1)")

        }
    }
}

private func runGit(_ arguments: [String], in directory: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
}
