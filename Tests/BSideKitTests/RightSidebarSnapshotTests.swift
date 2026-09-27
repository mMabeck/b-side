import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders the right sidebar offscreen and samples real composited pixels,
/// following the same conventions as `AuxiliaryWindowThemeSnapshotTests`.
@Suite(.serialized)
@MainActor
struct RightSidebarSnapshotTests {
    @Test("A populated Source Control panel renders readable rows over a themed background")
    func populatedPanelIsThemedAndLegible() async throws {
        let (window, palette, repoRoot) = try await renderOffscreen()
        defer {
            window.orderOut(nil)
            if let repoRoot { try? FileManager.default.removeItem(at: repoRoot) }
        }

        let deadline = Date().addingTimeInterval(5)
        var capturedBitmap: NSBitmapImageRep?
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let candidate = try? capture(window) {
                capturedBitmap = candidate
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        let bitmap = try #require(capturedBitmap)
        let surfaceBackground = NSColor(palette.surfaceBackground)
        let (minLuminance, maxLuminance) = luminanceRange(
            in: bitmap,
            xRange: 10..<(bitmap.pixelsWide - 10),
            yRange: 10..<(bitmap.pixelsHigh - 10)
        )
        // Row text (light against a dark themed surface, or vice versa) needs
        // to actually paint distinguishable pixels, not just the sidebar's
        // own flat background colour.
        #expect(maxLuminance - minLuminance > 0.15)
        let backgroundSample = try #require(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh - 4))
        #expect(isCloseToDarkThemeFamily(backgroundSample, background: surfaceBackground))
    }

    // MARK: - Shared offscreen render/capture plumbing

    /// Backs the rendered sidebar with a real throwaway git repo (via
    /// `TestRepo`) that has one staged file, one unstaged edit, and one
    /// untracked file, and selects the task pointed at it so the panel
    /// actually renders rows rather than an empty state.
    private func renderOffscreen() async throws -> (NSWindow, BSidePalette, URL?) {
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

        let previousDefinition = GhosttyResolvedTheme.shared.definition
        defer { GhosttyResolvedTheme.shared.update(previousDefinition) }
        GhosttyResolvedTheme.resolveEagerly()
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        #expect(GhosttyResolvedTheme.shared.definition?.name == ayuMirage.name)
        let theme = GhosttyResolvedTheme.shared

        // Per-test suite, not `.standard`: guards against the leaked
        // `settings.appearance.*` keys this suite's own comment history
        // warns about (see AGENTS.md's snapshot-testing gotchas).
        let defaults = UserDefaults(suiteName: "bside-sidebar-test-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let root = try TestRepo.makeTempDirectory()
        let repoRoot = root
        let repoURL = try await TestRepo.makeRepo(in: root)
        try "unstaged edit\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new file\n".write(to: repoURL.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try "staged content\n".write(to: repoURL.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["staged.txt"], at: repoURL)

        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }
        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Sidebar Snapshot", useWorktree: false)
        store.selectTask(task, project: project)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Explicitly themed, exactly as `themedWindow` does in production.
        // Without this the suite passes or fails depending on run *order*:
        // `NSApp.appearance` is process-global, and the suites that host a
        // whole `ContentView` set it as a side effect, so this view would
        // inherit dark appearance only when one of those happened to run
        // first. Alone, it rendered its AppKit tab strip in light `aqua` —
        // black labels on the dark themed surface, the very bug the
        // minimum-luminance assertion below exists to catch.
        window.appearance = theme.palette.preferredAppearance
        window.contentView = NSHostingView(rootView: RightSidebarView(store: store))
        window.setIsVisible(true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, theme.palette, repoRoot)
    }

    private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
            throw CaptureError.failed
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private enum CaptureError: Error { case failed }

    private func luminance(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    private func luminanceRange(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> (min: CGFloat, max: CGFloat) {
        var minL: CGFloat = 1
        var maxL: CGFloat = 0
        for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let l = luminance(of: color)
                minL = min(minL, l)
                maxL = max(maxL, l)
            }
        }
        return (minL, maxL)
    }
}

/// True if `color` is dark (low luminance, matching a dark Ghostty theme)
/// and reasonably close to the theme's own background — duplicated from
/// `AuxiliaryWindowThemeSnapshotTests` (private there) rather than shared,
/// per that file's own precedent.
private func isCloseToDarkThemeFamily(_ color: NSColor, background: NSColor, tolerance: CGFloat = 0.25) -> Bool {
    guard let color = color.usingColorSpace(.deviceRGB), let background = background.usingColorSpace(.deviceRGB) else {
        return false
    }
    let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    guard luminance < 0.5 else { return false }
    return abs(color.redComponent - background.redComponent) < tolerance
        && abs(color.greenComponent - background.greenComponent) < tolerance
        && abs(color.blueComponent - background.blueComponent) < tolerance
}

/// Guards the exact failure mode that made the icons silently disappear
/// twice while this strip was being built: SwiftUI's own segmented `Picker`
/// and `TabView` both *accept* a `Label` with a system image and then render
/// only its title, with no error and no compile-time complaint. Asserting on
/// the real `NSSegmentedControl` catches that directly — a segment that has
/// lost either half fails here rather than quietly shipping.
@MainActor
struct InspectorTabStripTests {
    private enum Tab: Hashable { case first, second }

    @Test("Every segment carries both an icon and a title")
    func segmentsCarryIconAndTitle() {
        var selection = Tab.first
        let strip = InspectorTabStrip(
            items: [
                .init(tab: Tab.first, title: "Source Control", systemImage: "arrow.triangle.branch"),
                .init(tab: Tab.second, title: "Subagents", systemImage: "person.2"),
            ],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            accent: .yellow
        )

        let control = strip.makeControl(target: nil, action: nil)

        #expect(control.segmentCount == 2)
        for index in 0..<control.segmentCount {
            #expect(control.image(forSegment: index) != nil)
            #expect(control.label(forSegment: index)?.isEmpty == false)
        }
        #expect(control.label(forSegment: 0) == "Source Control")
        #expect(control.label(forSegment: 1) == "Subagents")
        // Equal-width segments are what make the strip span the sidebar
        // rather than shrink-wrap into a small centred pill.
        #expect(control.segmentDistribution == .fillEqually)
        #expect(control.selectedSegment == 0)
    }
}
