import AppKit
import Foundation
import GhosttyTerminal
import OSLog
import SwiftUI

/// The single seam between DashNativeKit and libghostty. No other file in this
/// package imports `GhosttyKit` or `GhosttyTerminal` — per native-rewrite.md
/// §12, confining every direct call to one file means an upstream API break
/// (the embedding API is explicitly not stable upstream) is one file's worth
/// of work, not a package-wide hunt.
///
/// In practice this app makes **no raw C calls at all**. `GhosttyTerminal`'s
/// SwiftUI layer (`TerminalViewState` + `TerminalSurfaceView`) is high-level
/// enough that spawning a shell, resizing, pasting, and reading the user's
/// config are all plain Swift API calls the package itself exposes — the
/// `ghostty_*` C functions never appear below. This file remains the seam
/// anyway: it is still the only place that imports the package, so a renamed
/// or removed Swift API is still a one-file fix.
///
/// ### Ghostty actions this app handles
///
/// `GhosttyTerminal` dispatches most host-visible events (title, close,
/// clipboard confirmation, bell, desktop notifications, mouse shape, open
/// URL, ...) through `TerminalSurfaceViewDelegate` and its refinements
/// (`TerminalSurfaceTitleDelegate`, `TerminalSurfaceOpenURLDelegate`, etc.),
/// which only the AppKit/UIKit `TerminalView.delegate` property uses. This
/// app uses the SwiftUI surface (`TerminalSurfaceView` + `TerminalViewState`)
/// instead, which never adopts any of those delegate protocols — it reports
/// the same events through `TerminalViewState`'s `@Published` properties and
/// closures. That distinction is the point: the risk flagged in
/// native-rewrite.md §12 is a callback that claims to have handled an action
/// it has not (the library's internal action-dispatch callback in
/// `TerminalController+Callbacks.swift` reports `GHOSTTY_ACTION_OPEN_URL` as
/// handled only when a `TerminalSurfaceOpenURLDelegate` is adopted — claiming
/// a keybinding without a delegate to act on it would silently swallow it).
/// By never adopting a `TerminalSurfaceViewDelegate` at all, this app cannot
/// make that false claim: every action is either handled by one of the
/// explicit hooks below, or left to Ghostty's own default behaviour.
///
/// | Ghostty-reported event | Handled via | What this app does |
/// | --- | --- | --- |
/// | Title change | `TerminalViewState.title` (published) | read, currently unused (no window/tab title binding yet) |
/// | Surface close | `TerminalViewState.onClose` | logged; removing the surface from the UI is the caller's job, out of scope this stage |
/// | Clipboard read/write confirmation (OSC 52, `clipboard-write = ask`) | `TerminalViewState.onClipboardConfirmationRequest` | left `nil`: Ghostty's documented default applies — a program's read/write is denied silently, a user-initiated paste is allowed |
/// | Open URL, bell, desktop notification, mouse shape, scrollbar, focus, resize, grid resize, pwd, hover link, progress report, text selection request | *(no delegate adopted)* | Ghostty's own default behaviour for each; none is claimed as app-handled |
public enum GhosttyBridge {
    /// The user's own Ghostty config (`~/.config/ghostty/config`), if present.
    /// Passed straight through to `TerminalController`/`TerminalViewState` so
    /// the terminal renders with the user's real fonts, colours and theme —
    /// per native-rewrite.md §6 this app must not define any of its own.
    public static var userConfigFilePath: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // Known limitation, verified by hand (see Stage 2 build notes): a
    // `theme = <name>` line referencing one of upstream Ghostty's bundled
    // themes does not resolve here — this package ships only its own
    // shell-integration and terminfo resources, no theme corpus — and
    // libghostty rejects the *entire* config when one directive fails,
    // falling back wholesale to this package's built-in default theme
    // instead of the rest of the user's file. Every other directive (font
    // size, cursor style, literal colours, padding, ...) loads correctly;
    // only a named `theme` reference is affected. Confirmed by loading a
    // copy of a real `~/.config/ghostty/config` with its `theme` line
    // removed: `lastConfigurationIssue` went from a rejection to `nil` and
    // every remaining directive took effect. Left unfixed for this stage —
    // resolving named themes against the user's actual Ghostty.app bundle,
    // or degrading a single bad directive instead of the whole file, is
    // follow-up work, not something to route around silently here.
}

/// One libghostty surface: a real pty running a login shell, owned by the
/// `.exec` backend (which owns the pty and process lifecycle itself — see
/// native-rewrite.md §6, "what this buys for free").
@MainActor
public final class TerminalSurfaceHost: ObservableObject {
    private static let logger = Logger(subsystem: "ai.syv.dash-native", category: "terminal")

    let state: TerminalViewState

    /// - Parameters:
    ///   - workingDirectory: Where the shell starts. Callers pass the
    ///     selected project's path, falling back to the user's home
    ///     directory when nothing is selected.
    ///   - shell: Overrides `$SHELL` for testing. Defaults to the user's
    ///     login shell, invoked with `-l` so it reads the same profile files
    ///     an interactive terminal would.
    public init(workingDirectory: URL, shell: String? = nil) {
        state = TerminalViewState(configFilePath: GhosttyBridge.userConfigFilePath)

        let resolvedShell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory.path,
            command: "\(resolvedShell) -l"
        )

        state.onClose = { processAlive in
            Self.logger.info("surface closed, processAlive=\(processAlive, privacy: .public)")
        }

        if let issue = state.controller.lastConfigurationIssue {
            Self.logger.error("ghostty config issue: \(issue, privacy: .public)")
        }
    }

    /// Whether this surface should keep rendering. Per native-rewrite.md §6,
    /// a surface that stops being visible is marked not-visible rather than
    /// torn down: it keeps its grid, scrollback and session, and simply
    /// stops drawing frames nobody sees.
    public var isVisible: Bool {
        get { state.isSurfaceVisible }
        set { state.isSurfaceVisible = newValue }
    }

    public var title: String { state.title }

    /// Sends `text` as a paste, not keystrokes: a program with bracketed
    /// paste enabled receives it framed as a paste, so embedded newlines
    /// land in its edit line instead of running anything. Distinct from a
    /// real key press — see ``sendReturn()`` and native-rewrite.md §6.
    @discardableResult
    public func paste(_ text: String) -> Bool {
        state.paste(text: text)
    }

    /// Presses Return as a hardware key would — the key path, never
    /// paste-framed, unlike ``paste(_:)``.
    @discardableResult
    public func sendReturn() -> Bool {
        state.sendKey(.enter)
    }
}

/// SwiftUI view hosting one `TerminalSurfaceHost`. Everything outside this
/// file that wants a terminal on screen goes through this type; nothing else
/// needs to import `GhosttyTerminal`.
public struct TerminalHostView: View {
    @ObservedObject var host: TerminalSurfaceHost

    public init(host: TerminalSurfaceHost) {
        self.host = host
    }

    public var body: some View {
        TerminalSurfaceView(context: host.state)
    }
}
