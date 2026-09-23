import AppKit
import Foundation
import GhosttyTerminal
import GhosttyTheme
import OSLog
import SwiftUI

/// The single seam between BSideKit and libghostty. No other file in this
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
    static let logger = Logger(subsystem: "ai.syv.bside", category: "terminal-theme")

    /// The user's own Ghostty config, if present. Respects `XDG_CONFIG_HOME`
    /// like Ghostty itself does, falling back to `~/.config/ghostty/config`.
    public static var userConfigFilePath: String? {
        let configHome: URL
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdgConfigHome.isEmpty
        {
            configHome = URL(fileURLWithPath: xdgConfigHome)
        } else {
            configHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        }
        let path = configHome.appendingPathComponent("ghostty/config").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// One `theme = ...` directive as written in a Ghostty config file:
    /// either a single fixed name, or the light/dark adaptive form
    /// `theme = light:<name>,dark:<name>`.
    enum ThemeDirective: Equatable {
        case fixed(String)
        case adaptive(light: String, dark: String)
    }

    /// Diagnosed limitation, now worked around: `libghostty-spm` ships only
    /// its own theme corpus (`GhosttyTheme`), and rejects the *entire*
    /// config the moment a `theme = <name>` directive fails to resolve —
    /// even one this package's own catalog does define, because the base
    /// config load (before any programmatic override layer runs) parses it
    /// unconditionally. See native-rewrite.md §6. The fix pulls the `theme`
    /// line out before libghostty ever sees it, resolves it against
    /// `GhosttyThemeCatalog` ourselves, and reapplies the result as
    /// individual colour directives — which load fine, per the original
    /// diagnosis that every non-`theme` directive already worked.
    ///
    /// Everything else in the user's file, including comments and directive
    /// ordering, passes through untouched.
    static func extractThemeDirective(from contents: String) -> (sanitized: String, directive: ThemeDirective?) {
        var directive: ThemeDirective?
        var sanitizedLines: [String] = []

        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equalsIndex = trimmed.firstIndex(of: "=")
            else {
                sanitizedLines.append(line)
                continue
            }

            let key = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
            guard key == "theme" else {
                sanitizedLines.append(line)
                continue
            }

            let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            directive = parseThemeValue(value)
            // The line itself is dropped: its colours are reapplied
            // programmatically once resolved, instead of being handed back
            // to libghostty as a directive it cannot parse.
        }

        return (sanitizedLines.joined(separator: "\n"), directive)
    }

    private static func parseThemeValue(_ value: String) -> ThemeDirective {
        guard value.contains("light:") || value.contains("dark:") else {
            return .fixed(value)
        }

        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("light:") {
                light = String(piece.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
            } else if piece.hasPrefix("dark:") {
                dark = String(piece.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // A malformed adaptive form (missing one side) is treated as a
        // literal theme name rather than silently discarded — it will not
        // resolve, but the fallback logging in `resolveThemeDefinition`
        // still fires and names the actual bad value.
        guard let light, let dark else { return .fixed(value) }
        return .adaptive(light: light, dark: dark)
    }

    /// Resolves a directive to a catalog definition for the given
    /// appearance. Never throws: an unresolvable name is logged via `OSLog`
    /// and `nil` is returned so the caller falls back to the package's
    /// default theme while keeping the rest of the user's config intact.
    static func resolveThemeDefinition(
        _ directive: ThemeDirective?,
        preferDark: Bool
    ) -> GhosttyThemeDefinition? {
        guard let directive else { return nil }

        let name: String
        switch directive {
        case let .fixed(value):
            name = value
        case let .adaptive(light, dark):
            name = preferDark ? dark : light
        }

        guard let definition = GhosttyThemeCatalog.theme(named: name) else {
            logger.error("ghostty config: unknown theme \"\(name, privacy: .public)\" — falling back to default theme")
            return nil
        }
        return definition
    }

    /// Whether the current system appearance is dark, used to resolve the
    /// `light:/dark:` adaptive theme form.
    @MainActor
    static var systemPrefersDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The user's config, fully resolved: a `ConfigSource` libghostty can
    /// load without rejection, the colour theme to layer on top (the
    /// package's own `.default` if there was no `theme` directive to
    /// resolve), and the definition itself for ``GhosttyResolvedTheme`` to
    /// publish to the rest of the app.
    ///
    /// The resolved colours travel through `theme:`, not
    /// `terminalConfiguration:` — `TerminalController` always renders a
    /// theme layer last, on top of any session `terminalConfiguration`
    /// commands (see `resolveEffectiveConfig` upstream), so colours placed
    /// in `terminalConfiguration` are silently overwritten by the default
    /// light theme applied afterwards. `theme:` is the layer meant to win.
    struct ResolvedUserConfig {
        let configSource: TerminalController.ConfigSource
        let theme: TerminalTheme
        let themeDefinition: GhosttyThemeDefinition?
    }

    /// Key equivalents this *app* owns, unbound in the terminal's config so
    /// the surface does not swallow them.
    ///
    /// `AppTerminalView.performKeyEquivalent` asks
    /// `ghostty_surface_key_is_binding` whether a key is one of Ghostty's
    /// keybindings and, if so, handles it and returns `true`. AppKit offers
    /// the focused view's `performKeyEquivalent` a key *before* the main
    /// menu, so any shortcut Ghostty binds is consumed before the menu item
    /// that shares it can ever fire. Ghostty binds `cmd+,` to `open_config`
    /// by default, which is precisely why the App menu's Settings item did
    /// nothing whenever the terminal had focus — the menu was correct, the
    /// keystroke simply never reached it.
    ///
    /// `unbind` is Ghostty's own directive for releasing a binding, and is
    /// harmless for a key Ghostty never bound, so the app's other window
    /// shortcuts are listed too rather than waiting to be discovered the
    /// same painful way.
    ///
    /// Cmd+1…9 and Ctrl+1…9 are released for the same reason: Ghostty binds
    /// `cmd+1`…`cmd+9` to `goto_tab` by default, which would otherwise
    /// swallow `NavigationShortcuts`' "switch to active task"/"switch to
    /// project" digit shortcuts before the app's own menu ever saw them.
    /// Ctrl+digits are unbound too on the same defensive basis as `cmd+b`
    /// above, even though Ghostty has no built-in binding for them today.
    static let appOwnedKeybinds = """

    # Appended by B-Side: see GhosttyBridge.appOwnedKeybinds.
    keybind = cmd+,=unbind
    keybind = cmd+b=unbind
    keybind = cmd+opt+b=unbind
    \(digitUnbinds)

    """

    /// One `keybind = …=unbind` line per digit 1–9, for both `cmd+` and
    /// `ctrl+` modifiers — generated rather than spelled out eighteen times
    /// over, since `NavigationShortcuts` already treats "digits 1–9" as the
    /// shared range for both shortcut families.
    private static let digitUnbinds: String = (1...9)
        .flatMap { digit in ["keybind = cmd+\(digit)=unbind", "keybind = ctrl+\(digit)=unbind"] }
        .joined(separator: "\n")

    @MainActor
    static func resolveUserConfig(preferDark: Bool = systemPrefersDarkAppearance) -> ResolvedUserConfig {
        guard let path = userConfigFilePath else {
            // Still generated rather than `.none`: even with no user config
            // at all, the app's own key equivalents must be released from
            // Ghostty's defaults.
            return ResolvedUserConfig(
                configSource: .generated(appOwnedKeybinds),
                theme: .default,
                themeDefinition: nil
            )
        }

        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            // The file exists but couldn't be read (permissions, bad
            // encoding, ...) — distinct from having no config at all, and
            // otherwise silently falls back to the default theme with no
            // way for the user to tell why.
            logger.error("ghostty config: failed to read \(path, privacy: .public): \(error, privacy: .public)")
            return ResolvedUserConfig(
                configSource: .generated(appOwnedKeybinds),
                theme: .default,
                themeDefinition: nil
            )
        }

        let (sanitized, directive) = extractThemeDirective(from: raw)
        // Passes through as generated text rather than `.file(path)` even
        // when there's no theme directive to resolve, since the unbinds
        // have to be appended to it either way.
        let definition = resolveThemeDefinition(directive, preferDark: preferDark)
        let theme = definition?.toTerminalTheme() ?? .default
        return ResolvedUserConfig(
            configSource: .generated(sanitized + appOwnedKeybinds),
            theme: theme,
            themeDefinition: definition
        )
    }
}

/// Publishes the Ghostty theme resolved from the user's own
/// `~/.config/ghostty/config` (see ``GhosttyBridge``) so SwiftUI views
/// outside the terminal grid — sidebar, subagent cards, window chrome — can
/// mirror the user's real terminal theme instead of hardcoding colours.
/// `definition` is `nil` until a ``TerminalSurfaceHost`` resolves a config
/// with a recognised `theme` directive; readers should treat `nil` as "no
/// opinion, use system colours."
///
/// `definition` only carries the raw theme; ``BSidePalette/themed(from:)``
/// (exposed here as ``palette``) is what turns it into semantic colours by
/// role, so callers don't need to know which ANSI slot means what.
@MainActor
public final class GhosttyResolvedTheme: ObservableObject {
    public static let shared = GhosttyResolvedTheme()

    @Published public private(set) var definition: GhosttyThemeDefinition?

    init(definition: GhosttyThemeDefinition? = nil) {
        self.definition = definition
    }

    func update(_ definition: GhosttyThemeDefinition?) {
        self.definition = definition
    }

    /// Resolves the user's Ghostty theme from disk and publishes it to
    /// `target` (``shared`` by default), independent of any terminal surface
    /// being constructed. Called at app launch so every window — including
    /// ones that never host a terminal, like Settings or the New Task sheet
    /// — sees the real theme on its first frame instead of
    /// ``BSidePalette/fallback``. `TerminalSurfaceHost` still calls
    /// ``update(_:)`` itself when it starts a surface, which is harmless: it
    /// re-resolves the same config and republishes the same result.
    ///
    /// Takes an explicit `target` (rather than always writing straight to
    /// ``shared``) so tests can exercise this against a private instance
    /// instead of the process-global singleton other concurrently running
    /// tests may also be reading or writing.
    public static func resolveEagerly(into target: GhosttyResolvedTheme = shared) {
        target.update(GhosttyBridge.resolveUserConfig().themeDefinition)
    }

    /// The full semantic palette for the whole app UI, derived from the
    /// resolved theme when one exists, or ``BSidePalette/fallback`` (plain
    /// system colours) otherwise. This is the single source of colour truth
    /// for everything outside the terminal grid — window chrome, sidebars,
    /// drawer, settings, subagent cards.
    public var palette: BSidePalette {
        definition.map(BSidePalette.themed(from:)) ?? .fallback
    }
}

/// One libghostty surface: a real pty running a login shell, owned by the
/// `.exec` backend (which owns the pty and process lifecycle itself — see
/// native-rewrite.md §6, "what this buys for free").
@MainActor
public final class TerminalSurfaceHost: ObservableObject {
    private static let logger = Logger(subsystem: "ai.syv.bside", category: "terminal")

    let state: TerminalViewState

    /// - Parameters:
    ///   - workingDirectory: Where the shell starts. Callers pass the
    ///     selected project's path, falling back to the user's home
    ///     directory when nothing is selected.
    ///   - shell: Overrides `$SHELL` for testing. Defaults to the user's
    ///     login shell, invoked with `-l` so it reads the same profile files
    ///     an interactive terminal would.
    public init(workingDirectory: URL, shell: String? = nil) {
        let resolvedConfig = GhosttyBridge.resolveUserConfig()
        state = TerminalViewState(
            configSource: resolvedConfig.configSource,
            theme: resolvedConfig.theme
        )
        GhosttyResolvedTheme.shared.update(resolvedConfig.themeDefinition)

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
///
/// `focusedTaskID`/`taskID` are optional and only wired up by callers that
/// keep several hosts mounted at once and need real (not merely visual)
/// first-responder control over which one is live — see `MainAreaView`'s doc
/// comment for why `opacity`/`allowsHitTesting` alone cannot move keyboard
/// focus away from a hidden host. Left `nil` for a single-host caller like
/// `TerminalDrawerView`, where there is nothing else competing for focus.
public struct TerminalHostView: View {
    @ObservedObject var host: TerminalSurfaceHost
    var focusedTaskID: FocusState<Int64?>.Binding?
    var taskID: Int64?

    public init(host: TerminalSurfaceHost, focusedTaskID: FocusState<Int64?>.Binding? = nil, taskID: Int64? = nil) {
        self.host = host
        self.focusedTaskID = focusedTaskID
        self.taskID = taskID
    }

    public var body: some View {
        if let focusedTaskID, let taskID {
            TerminalSurfaceView(context: host.state)
                .terminalFocused(focusedTaskID, equals: taskID)
        } else {
            TerminalSurfaceView(context: host.state)
        }
    }
}
