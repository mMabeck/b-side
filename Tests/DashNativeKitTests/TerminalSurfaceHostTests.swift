import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DashNativeKit

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
}
