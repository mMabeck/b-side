import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BSideKit

/// The surface exists only once a view attaches, so tests host it in an offscreen, never-ordered-front NSWindow.
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

        hostA.focus()
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.firstResponder === hostA.state.attachedPlatformView)

        // A re-render of the focused host must not steal focus (the old @FocusState bridge resigned it).
        hostA.objectWillChange.send()
        hostB.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.firstResponder === hostA.state.attachedPlatformView)

        hostB.focus()
        hostA.resignFocus()
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.firstResponder === hostB.state.attachedPlatformView)

        hostB.resignFocus()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hostA.hasKeyboardFocus && !hostB.hasKeyboardFocus)

        window.orderOut(nil)
    }

    @Test func commandStartsInGivenWorkingDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-host-cwd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("cwd-marker")

        let script = dir.appendingPathComponent("launch.sh")
        try "#!/bin/sh\npwd > \(marker.path)\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let host = TerminalSurfaceHost(workingDirectory: dir, command: script.path)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TerminalHostView(host: host))
        window.setIsVisible(true)
        try await Task.sleep(for: .seconds(2))

        let contents = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(contents == dir.resolvingSymlinksInPath().path)

        window.orderOut(nil)
    }
}

private struct TwoHostFocusHarness: View {
    var hostA: TerminalSurfaceHost
    var hostB: TerminalSurfaceHost

    var body: some View {
        ZStack {
            TerminalHostView(host: hostA)
            TerminalHostView(host: hostB)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }
}

/// libghostty rejects the entire config if one directive fails to parse, so unbinds are checked against a real surface.
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
