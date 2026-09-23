import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BSideKit

/// Exercises the real `.exec` backend end to end: a live pty, not a mock.
/// `TerminalViewState.surface` only appears once a platform view attaches (see
/// GhosttyBridge.swift), so each test hosts its `TerminalHostView` in a real,
/// never-ordered-front `NSWindow` positioned off any actual screen.
@MainActor
struct TerminalSurfaceHostTests {
    private func makeAttachedHost(workingDirectory: URL) -> (TerminalSurfaceHost, NSWindow) {
        let host = TerminalSurfaceHost(workingDirectory: workingDirectory, shell: "/bin/zsh")
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TerminalHostView(host: host))
        window.setIsVisible(true)
        return (host, window)
    }

    /// Keyboard input (`sendReturn`, a real key-press path) reaches the shell,
    /// and a paste is a genuinely distinct path from keystrokes: a pasted
    /// `\r` sits in the shell's edit line instead of submitting it.
    @Test func pasteDoesNotSubmitButReturnDoes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("paste-marker")

        let (host, window) = makeAttachedHost(workingDirectory: dir)
        try await Task.sleep(for: .seconds(2))

        _ = host.paste("touch \(marker.path)\r")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        _ = host.sendReturn()
        try await Task.sleep(for: .seconds(1))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        window.orderOut(nil)
    }

    /// A surface marked not-visible keeps running rather than being torn
    /// down: input still lands and output is still produced while hidden.
    @Test func hiddenSurfaceKeepsRunning() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("hidden-marker")

        let (host, window) = makeAttachedHost(workingDirectory: dir)
        try await Task.sleep(for: .seconds(2))

        host.isVisible = false
        _ = host.paste("touch \(marker.path)")
        _ = host.sendReturn()
        try await Task.sleep(for: .seconds(1))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        host.isVisible = true
        window.orderOut(nil)
    }

    /// Regression test for `MainAreaView.syncFocus()`: mounts two hosts the
    /// way it does (both in the tree, one shared `@FocusState`, the same
    /// `.terminalFocused(_:equals:)` bridge), then moves focus the
    /// deterministic way — `TerminalViewState.requestFocus()` on the newly
    /// visible host — and checks first responder actually lands there.
    /// `@FocusState` itself isn't exercised as the acquisition path here:
    /// per `requestFocus()`'s own doc comment, that bridge is best-effort,
    /// which is exactly why `syncFocus()` no longer relies on it alone.
    @Test func requestFocusMovesFirstResponderDeterministically() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-focus-test-a-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-focus-test-b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let hostA = TerminalSurfaceHost(workingDirectory: dirA, shell: "/bin/zsh")
        let hostB = TerminalSurfaceHost(workingDirectory: dirB, shell: "/bin/zsh")
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TwoHostFocusHarness(hostA: hostA, hostB: hostB))
        window.setIsVisible(true)
        try await Task.sleep(for: .seconds(2))

        // Establish hostA as focused the same deterministic way `syncFocus()`
        // does on first mount: FocusState alone (see `onAppear` in
        // `TwoHostFocusHarness`) does not reliably land first responder with
        // two hosts competing for one `@FocusState` — that gap is exactly
        // the defect `requestFocus()` closes.
        hostA.state.requestFocus()
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.firstResponder === hostA.state.attachedPlatformView)

        // Switch to hostB the way `syncFocus()` does: FocusState plus the
        // deterministic `requestFocus()` call, not FocusState alone.
        hostB.state.requestFocus()
        try await Task.sleep(for: .milliseconds(500))

        #expect(window.firstResponder === hostB.state.attachedPlatformView)

        window.orderOut(nil)
    }
}

/// Mounts two hosts the way `MainAreaView` does: both in the tree, one
/// shared `@FocusState`, `.terminalFocused(_:equals:)` bound per host, only
/// one visible/hit-testable at a time.
private struct TwoHostFocusHarness: View {
    var hostA: TerminalSurfaceHost
    var hostB: TerminalSurfaceHost
    @FocusState private var focusedID: Int64?

    var body: some View {
        ZStack {
            TerminalHostView(host: hostA, focusedTaskID: $focusedID, taskID: 0)
            TerminalHostView(host: hostB, focusedTaskID: $focusedID, taskID: 1)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear { focusedID = 0 }
    }
}

/// libghostty rejects an *entire* config when a single directive fails to
/// parse — the failure mode that once cost this app its whole theme over one
/// `theme =` line. The `keybind = …=unbind` directives `GhosttyBridge`
/// appends to release the app's own key equivalents are therefore checked
/// against a real surface here, not merely asserted as strings, so a syntax
/// mistake surfaces as a test failure instead of silently discarding every
/// setting the user wrote.
@MainActor
struct GeneratedKeybindConfigTests {
    @Test("A real surface accepts the generated config, unbinds included")
    func realSurfaceAcceptsGeneratedConfig() async throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-keybind-surface-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "theme = Ayu Mirage\nfont-size = 14\n".write(
            to: configDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: configHome) }

        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        let host = TerminalSurfaceHost(
            workingDirectory: FileManager.default.temporaryDirectory,
            shell: "/bin/zsh"
        )
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TerminalHostView(host: host))
        window.setIsVisible(true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))

        let issue = host.state.controller.lastConfigurationIssue
        if let issue {
            Issue.record("libghostty rejected the generated config: \(issue)")
        }
        #expect(issue == nil)
    }

    /// `envVars` (what `MainAreaView.ensureHost` fills with
    /// `PiSessionService.launchEnvironment`) must actually reach the
    /// spawned process's environment, not just get threaded through to
    /// `TerminalSurfaceOptions` and dropped.
    @Test func envVarsReachTheSpawnedProcess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-env-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("env-marker")

        let host = TerminalSurfaceHost(
            workingDirectory: dir,
            shell: "/bin/zsh",
            envVars: PiSessionService.launchEnvironment(taskId: 99, subagentEndpoint: "127.0.0.1:12345")
        )
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TerminalHostView(host: host))
        window.setIsVisible(true)
        try await Task.sleep(for: .seconds(2))

        _ = host.paste("echo \"$BSIDE_TASK_ID:$BSIDE_SUBAGENT_ENDPOINT\" > \(marker.path)\r")
        _ = host.sendReturn()
        try await Task.sleep(for: .seconds(1))

        let contents = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(contents == "99:127.0.0.1:12345")

        window.orderOut(nil)
    }
}
