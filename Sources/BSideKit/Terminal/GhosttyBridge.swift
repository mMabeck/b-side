import AppKit
import Combine
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
/// | Bell (OSC 9 falls back to this when a program doesn't emit OSC 777) | `TerminalViewState.bellCount`/`lastBellAt` (published) | republished as `TerminalSurfaceHost.bellCount`; `TerminalAlertBridge` forwards it to `ProjectsStore.handleTerminalBell`, which plays a sound, posts a native notification, and marks the sidebar row needing attention |
/// | Desktop notification (OSC 777) | `TerminalViewState.lastDesktopNotificationTitle`/`Body`/`At` (published) | republished as `TerminalSurfaceHost.lastDesktopNotification*`; `TerminalAlertBridge` forwards it to `ProjectsStore.handleTerminalDesktopNotification`, classified via `TaskAlertClassifier` into a question or finished alert |
/// | Open URL, mouse shape, scrollbar, focus, resize, grid resize, pwd, hover link, progress report, text selection request | *(no delegate adopted)* | Ghostty's own default behaviour for each; none is claimed as app-handled |
public enum GhosttyBridge {
    static let logger = Logger(subsystem: "dev.mabeck.bside", category: "terminal-theme")

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
    /// `theme = light:<name>,dark:<name>`. B-Side never derives appearance
    /// from the macOS system setting, so the adaptive form is still parsed
    /// (a user's own config may use it) but always resolves to `dark` — see
    /// ``resolveThemeDefinition(_:)``.
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
    ///
    /// An adaptive `light:X,dark:Y` directive always resolves to `dark`:
    /// B-Side never derives its appearance from the macOS system setting,
    /// so there is no light/dark choice to make here — the light name is
    /// still parsed (a user's own config may use the adaptive form) but
    /// never selected.
    static func resolveThemeDefinition(_ directive: ThemeDirective?) -> GhosttyThemeDefinition? {
        guard let directive else { return nil }

        let name: String
        switch directive {
        case let .fixed(value):
            name = value
        case let .adaptive(_, dark):
            name = dark
        }

        guard let definition = ThemeCatalogSource.theme(named: name) else {
            logger.error("ghostty config: unknown theme \"\(name, privacy: .public)\" — falling back to default theme")
            return nil
        }
        return definition
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
    ///
    /// Cmd+Q and Cmd+W are released for the same underlying reason as every
    /// entry above: Ghostty's macOS defaults bind `cmd+q` to `quit` and
    /// `cmd+w` to `close_surface`, which the *terminal surface itself* would
    /// act on — quitting or tearing down libghostty's own state — before
    /// AppKit's menu (the standard Quit item, and `TerminalCommands`' own
    /// Cmd+W) ever sees the key. Left un-unbound, that's exactly the "Cmd+Q
    /// doesn't quit" symptom: no app code was ignoring the shortcut, the
    /// surface consumed it first.
    ///
    /// Cmd+N and Cmd+Shift+N are released too: Ghostty binds `cmd+n` to
    /// `new_window` by default, which would otherwise swallow
    /// `ProjectCommands`' "New Task"/"Add Project…" shortcuts the same way;
    /// `cmd+shift+n` is unbound defensively alongside it, on the same basis
    /// as `cmd+opt+b` above, even with no confirmed Ghostty default for it.
    /// Cmd+H (hide) and Cmd+M (minimize) are standard window/app shortcuts
    /// with no app menu item of their own here, but are released
    /// defensively for the same reason — both are exactly the shape of
    /// standard AppKit shortcut a terminal emulator's defaults are prone to
    /// binding out from under an embedding app. Cmd+Shift+R is unbound on
    /// the same defensive basis — Ghostty's own default binds plain Cmd+R
    /// to `reload_config`, and `TerminalCommands`' "Restart Pi Session"
    /// deliberately uses Cmd+Shift+R instead of Cmd+R to avoid colliding
    /// with it outright. Cmd+Shift+D (`ChangesCommands`' "Show All Changes")
    /// is released on the same defensive basis, with no confirmed Ghostty
    /// default either.
    ///
    /// Copy/paste/select-all/find (`cmd+c`/`cmd+v`/`cmd+a`/`cmd+f`) are
    /// deliberately left bound to the terminal: those are exactly the keys a
    /// focused terminal surface should keep handling itself.
    static let appOwnedKeybinds = """

    # Appended by B-Side: see GhosttyBridge.appOwnedKeybinds.
    keybind = cmd+,=unbind
    keybind = cmd+b=unbind
    keybind = cmd+opt+b=unbind
    keybind = cmd+q=unbind
    keybind = cmd+w=unbind
    keybind = cmd+n=unbind
    keybind = cmd+shift+n=unbind
    keybind = cmd+h=unbind
    keybind = cmd+m=unbind
    keybind = cmd+shift+r=unbind
    keybind = cmd+shift+d=unbind
    \(digitUnbinds)

    """

    /// One `keybind = …=unbind` line per digit 1–9, for both `cmd+` and
    /// `ctrl+` modifiers — generated rather than spelled out eighteen times
    /// over, since `NavigationShortcuts` already treats "digits 1–9" as the
    /// shared range for both shortcut families.
    private static let digitUnbinds: String = (1...9)
        .flatMap { digit in ["keybind = cmd+\(digit)=unbind", "keybind = ctrl+\(digit)=unbind"] }
        .joined(separator: "\n")

    /// - Parameter override: The Appearance tab's preference, if any — see
    ///   ``ThemeOverride``. When non-`nil` it takes the place of whatever
    ///   `theme = ...` directive the config file itself has (or lacks);
    ///   every other line of the user's config still passes through
    ///   untouched, exactly as it does with no override at all. Defaults to
    ///   the live preference so ordinary callers need not know this exists,
    ///   while tests can pass an explicit value to keep resolution pure.
    @MainActor
    static func resolveUserConfig(
        override: ThemeDirective? = ThemeOverride.currentDirective()
    ) -> ResolvedUserConfig {
        guard let path = userConfigFilePath else {
            // Still generated rather than `.none`: even with no user config
            // at all, the app's own key equivalents must be released from
            // Ghostty's defaults.
            let definition = resolveThemeDefinition(override)
            return ResolvedUserConfig(
                configSource: .generated(appOwnedKeybinds),
                theme: definition?.toTerminalTheme() ?? .default,
                themeDefinition: definition
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
            let definition = resolveThemeDefinition(override)
            return ResolvedUserConfig(
                configSource: .generated(appOwnedKeybinds),
                theme: definition?.toTerminalTheme() ?? .default,
                themeDefinition: definition
            )
        }

        let (sanitized, configDirective) = extractThemeDirective(from: raw)
        // The override, when set, replaces the config file's own directive
        // outright rather than layering on top of it — exactly one theme
        // directive is ever in effect.
        let directive = override ?? configDirective
        // Passes through as generated text rather than `.file(path)` even
        // when there's no theme directive to resolve, since the unbinds
        // have to be appended to it either way.
        let definition = resolveThemeDefinition(directive)
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
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "terminal")

    let state: TerminalViewState

    /// Republished from `TerminalViewState.bellCount`/`lastDesktopNotification*`
    /// so a caller (`TerminalAlertBridge`) can observe them without itself
    /// importing `GhosttyTerminal` — this file remains the only one that
    /// does, per the doc comment above.
    @Published public private(set) var bellCount: Int = 0
    @Published public private(set) var lastDesktopNotificationTitle: String?
    @Published public private(set) var lastDesktopNotificationBody: String?
    @Published public private(set) var lastDesktopNotificationAt: Date?

    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - workingDirectory: Where the shell starts. Callers pass the
    ///     selected project's path, falling back to the user's home
    ///     directory when nothing is selected.
    ///   - shell: Overrides `$SHELL` for testing. Defaults to the user's
    ///     login shell, invoked with `-l` so it reads the same profile files
    ///     an interactive terminal would. Ignored when `command` is given.
    ///   - command: Overrides the process spawned in the surface, taking
    ///     the place of `shell -l`. The task agent terminal passes a
    ///     `PiSessionService.launchCommand(...)` here; the bottom drawer's
    ///     scratch terminal leaves this `nil` to keep the plain login shell.
    ///   - envVars: Extra environment variables the spawned process (and
    ///     everything it forks) inherits. The task agent terminal passes
    ///     `PiSessionService.launchEnvironment(...)` here so its `pi`
    ///     process can find `SubagentEventServer`; the scratch terminal
    ///     leaves this empty.
    ///   - onExit: Called when the surface's own process exits on its own
    ///     (not via an explicit teardown the caller already knows about),
    ///     with whether the process was still alive at close. `SubagentPaneStore`
    ///     passes this to remove a child pane when its command exits instead
    ///     of waiting for an explicit `/close` call.
    public init(
        workingDirectory: URL,
        shell: String? = nil,
        command: String? = nil,
        envVars: [String: String] = [:],
        onExit: ((Bool) -> Void)? = nil
    ) {
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
            envVars: envVars,
            command: command ?? "\(resolvedShell) -l"
        )

        state.onClose = { processAlive in
            Self.logger.info("surface closed, processAlive=\(processAlive, privacy: .public)")
            onExit?(processAlive)
        }

        if let issue = state.controller.lastConfigurationIssue {
            Self.logger.error("ghostty config issue: \(issue, privacy: .public)")
        }

        state.$bellCount
            .dropFirst()
            .sink { [weak self] count in self?.bellCount = count }
            .store(in: &cancellables)

        // `.at` publishes last, after `title`/`body` have already been
        // assigned (see `TerminalViewState+Delegate.swift`), so reading
        // `state`'s own properties here — not the publisher's payload — is
        // always the fully-updated triple, not a stale title paired with a
        // fresh timestamp.
        state.$lastDesktopNotificationAt
            .compactMap { $0 }
            .sink { [weak self] at in
                guard let self else { return }
                lastDesktopNotificationTitle = state.lastDesktopNotificationTitle
                lastDesktopNotificationBody = state.lastDesktopNotificationBody
                lastDesktopNotificationAt = at
            }
            .store(in: &cancellables)

        // Registered so a later Appearance-tab theme change
        // (``GhosttyThemeController/reapply()``) can re-theme this surface
        // in place — see ``TerminalSurfaceHostRegistry``.
        TerminalSurfaceHostRegistry.shared.register(self)
    }

    deinit {
        // `deinit` on a `@MainActor` class runs nonisolated (see
        // `ThemedWindow.swift`'s `VibrancyGuardian` for the same pattern);
        // the registry's dictionary is only ever touched from the main
        // actor, so this is safe precisely because nothing else can race a
        // deallocating object's own teardown.
        MainActor.assumeIsolated {
            TerminalSurfaceHostRegistry.shared.unregister(self)
        }
    }

    /// Backs a surface with an `InMemoryTerminalSession` instead of a real
    /// pty (`.exec`) — used only by `SubagentStripHost` today. No
    /// `workingDirectory`/`command`/`onExit`: there is no process, so
    /// nothing about process lifecycle applies.
    fileprivate init(inMemorySession: InMemoryTerminalSession) {
        let resolvedConfig = GhosttyBridge.resolveUserConfig()
        state = TerminalViewState(
            configSource: resolvedConfig.configSource,
            theme: resolvedConfig.theme
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(inMemorySession))
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

    /// Makes this surface the window's first responder, replaying once its
    /// view is attached if it isn't yet. See ``TerminalHostView`` for why
    /// focus is driven imperatively rather than through `@FocusState`.
    public func focus() {
        state.requestFocus()
    }

    /// Whether `responder` is some terminal surface's view — lets callers
    /// outside this file ask "is a terminal already taking keystrokes?"
    /// without importing `GhosttyTerminal`.
    public static func isTerminalView(_ responder: NSResponder?) -> Bool {
        responder is TerminalView
    }

    /// Whether this surface's view currently holds keyboard focus.
    public var hasKeyboardFocus: Bool {
        guard let view = state.attachedPlatformView, let window = view.window else { return false }
        return window.firstResponder === view
    }

    /// Hands first responder back to the window if this surface holds it,
    /// so a hidden surface stops receiving keystrokes. Deferred one runloop
    /// hop so it lands after any `focus()` replay already queued for this
    /// surface (`requestFocus()` hops the runloop too) instead of being
    /// undone by it.
    public func resignFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, hasKeyboardFocus else { return }
            state.attachedPlatformView?.window?.makeFirstResponder(nil)
        }
    }

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
/// Deliberately *not* bound to a `@FocusState` via `.terminalFocused`:
/// that bridge re-syncs first responder on every `updateNSView`, resigning
/// the surface whenever the binding reads false — and SwiftUI resets an
/// unanchored `@FocusState` to nil on its own. Any re-render of this view
/// (a title change, a bell, ...) could then silently take keyboard focus
/// away from the terminal being typed in until it was clicked. Callers move
/// focus with ``TerminalSurfaceHost/focus()``/``TerminalSurfaceHost/resignFocus()``
/// instead.
public struct TerminalHostView: View {
    @ObservedObject var host: TerminalSurfaceHost

    public init(host: TerminalSurfaceHost) {
        self.host = host
    }

    public var body: some View {
        TerminalSurfaceView(context: host.state)
    }
}

/// One in-memory Ghostty surface used purely to render the subagent card
/// strip (native-rewrite.md §"Subagents, and replacing tmux"): no pty, no
/// child process — `render(lines:)` writes plain ANSI bytes
/// (`SubagentStripRenderer`'s output) directly into the terminal's grid, and
/// mouse clicks over the strip come back out through `onHostInput` as raw
/// SGR report bytes (`InMemoryTerminalSession`'s `write` handler fires
/// whenever Ghostty would otherwise have sent bytes to a real pty's stdin —
/// keystrokes, or here, mouse reports — since there is no pty to send them
/// to). `SubagentStripMouseParser` turns those bytes into clicks.
@MainActor
public final class SubagentStripHost: ObservableObject {
    public let hostView: TerminalSurfaceHost
    private let session: InMemoryTerminalSession

    /// Raw bytes Ghostty would have sent to a real process's stdin — in
    /// practice, for this surface, SGR mouse reports once
    /// ``enableMouseReporting()`` has run. Set by the caller
    /// (`SubagentStripView`) before the surface can report anything useful.
    public var onHostInput: ((Data) -> Void)?

    /// The most recent grid metrics Ghostty has reported for this surface,
    /// via the in-memory session's resize callback — `nil` until the
    /// surface first attaches to a real view and reports one.
    @Published public private(set) var latestViewport: InMemoryTerminalViewport?

    public init() {
        var capturedSession: InMemoryTerminalSession!
        let box = HostInputBox()
        capturedSession = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in box.host?.onHostInput?(data) }
            },
            resize: { viewport in
                Task { @MainActor in box.host?.latestViewport = viewport }
            }
        )
        session = capturedSession
        hostView = TerminalSurfaceHost(inMemorySession: capturedSession)
        box.host = self
    }

    /// Turns on SGR mouse reporting (`\e[?1000h\e[?1006h`) so a click over
    /// this surface is delivered back through ``onHostInput`` instead of
    /// being handled as ordinary terminal input. Bytes sent before a real
    /// view has attached are buffered by the session and flushed on attach,
    /// so this is safe to call immediately after ``init()``.
    public func enableMouseReporting() {
        session.receive("\u{1B}[?1000h\u{1B}[?1006h")
    }

    /// Clears the grid and redraws it from `lines` — the strip is a
    /// full-repaint surface, not an incremental one, since
    /// `SubagentStripRenderer` re-renders the whole thing on every tick
    /// anyway. Cursor stays hidden: nothing in the strip is ever "typed
    /// into".
    public func render(lines: [String]) {
        let body = (["\u{1B}[H\u{1B}[2J\u{1B}[?25l"] + lines).joined(separator: "\r\n")
        session.receive(body)
    }

    /// The point height needed to show `rows` terminal rows, derived from
    /// the surface's own reported cell metrics once available (device
    /// pixels, divided by the screen's backing scale), or a reasonable
    /// fallback for the brief window before the surface has attached and
    /// reported its first viewport.
    public func pointHeight(forRows rows: Int) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let viewport = latestViewport, viewport.cellHeightPixels > 0 else {
            return CGFloat(rows) * 18
        }
        return CGFloat(viewport.cellHeightPixels) / scale * CGFloat(rows)
    }

    public var columns: Int {
        Int(latestViewport?.columns ?? 0)
    }

    /// `InMemoryTerminalSession`'s closures are captured at `init` time,
    /// before `self` exists — this indirection lets them reach the fully
    /// constructed host afterwards instead of requiring a two-phase init.
    private final class HostInputBox: @unchecked Sendable {
        weak var host: SubagentStripHost?
    }
}

extension TerminalSurfaceHost {
    /// A `TerminalSurfaceHost` backed by an in-memory session instead of a
    /// real pty/exec surface — for tests that need to create several panes
    /// at once (`SubagentPaneStoreTests`, `SubagentEventServerTests`) without
    /// each one spawning a real Ghostty exec surface: spawning many real
    /// exec surfaces back-to-back crashes libghostty under `swift test`.
    static func makeInMemoryForTesting() -> TerminalSurfaceHost {
        TerminalSurfaceHost(inMemorySession: InMemoryTerminalSession(write: { _ in }, resize: { _ in }))
    }
}

/// Invisible per-task bridge from `TerminalSurfaceHost`'s republished bell/
/// desktop-notification signals to `ProjectsStore.handleTerminalBell`/
/// `handleTerminalDesktopNotification`. Mounted alongside `TerminalHostView`
/// in `MainAreaView.body` for every cached host — live or hidden — so a
/// question raised in a background task still triggers its sound,
/// notification, and sidebar attention dot.
/// Tracks every live ``TerminalSurfaceHost`` so a theme change can reach
/// them without restarting the app. Entries are weak: a closed host simply
/// stops receiving updates once ``TerminalSurfaceHost/deinit`` unregisters
/// it, with nothing else to tear down.
@MainActor
final class TerminalSurfaceHostRegistry {
    static let shared = TerminalSurfaceHostRegistry()

    private var hosts: [ObjectIdentifier: WeakHostBox] = [:]

    private struct WeakHostBox {
        weak var host: TerminalSurfaceHost?
    }

    private init() {}

    func register(_ host: TerminalSurfaceHost) {
        hosts[ObjectIdentifier(host)] = WeakHostBox(host: host)
    }

    func unregister(_ host: TerminalSurfaceHost) {
        hosts.removeValue(forKey: ObjectIdentifier(host))
    }

    /// Re-themes every live surface in place. `TerminalViewState.setTheme(_:)`
    /// reconfigures the running ghostty surface with new colours without
    /// touching its pty or session — the terminal never restarts, it just
    /// redraws in the new theme.
    func applyThemeToAllHosts(_ theme: TerminalTheme) {
        for box in hosts.values {
            box.host?.state.setTheme(theme)
        }
    }
}

/// Coordinates a theme change across the whole running app: re-resolves the
/// user's config — folding in the Appearance tab's override via
/// ``ThemeOverride`` — republishes the result to ``GhosttyResolvedTheme/shared``
/// (which every `themedWindow`-modified window observes and redraws from),
/// updates `NSApp`'s own appearance immediately rather than waiting for a
/// window to redraw, and re-themes every live terminal through
/// ``TerminalSurfaceHostRegistry``.
@MainActor
public enum GhosttyThemeController {
    static func reapply() {
        let resolved = GhosttyBridge.resolveUserConfig()
        GhosttyResolvedTheme.shared.update(resolved.themeDefinition)
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance
        TerminalSurfaceHostRegistry.shared.applyThemeToAllHosts(resolved.theme)
    }
}

public struct TerminalAlertBridge: View {
    @ObservedObject var host: TerminalSurfaceHost
    var store: ProjectsStore
    var taskID: Int64

    public init(host: TerminalSurfaceHost, store: ProjectsStore, taskID: Int64) {
        self.host = host
        self.store = store
        self.taskID = taskID
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: host.bellCount) { _, _ in
                store.handleTerminalBell(taskID: taskID)
            }
            .onChange(of: host.lastDesktopNotificationAt) { _, _ in
                store.handleTerminalDesktopNotification(
                    taskID: taskID,
                    title: host.lastDesktopNotificationTitle ?? "",
                    body: host.lastDesktopNotificationBody ?? ""
                )
            }
    }
}

/// Makes trackpad scrolling in a terminal feel like Ghostty.app.
///
/// Ghostty.app's `SurfaceView.scrollWheel` doubles precise (trackpad /
/// Magic Mouse) deltas before handing them to libghostty — "it feels
/// better" per its own comment. `libghostty-spm`'s `AppTerminalView`
/// forwards the raw deltas instead, so the same config scrolled at half
/// speed here. The view is created inside the package's SwiftUI
/// `TerminalSurfaceView` and can't be subclassed, so a local monitor
/// intercepts the event, sends the doubled scroll through the view's public
/// `sendMouseScroll`, and swallows the original. Wheel-mouse (line-based)
/// events are left untouched, as Ghostty.app does.
@MainActor
public enum TerminalScrollRouter {
    /// Ghostty.app's precise-scroll multiplier.
    static let preciseMultiplier: Double = 2

    /// Installs the monitor once for the app's lifetime. Call once, from
    /// `BSideApp.init()`.
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            route(event) ? nil : event
        }
    }

    /// `true` if `event` was delivered to a terminal under the pointer and
    /// should be swallowed.
    @discardableResult
    static func route(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel,
              event.hasPreciseScrollingDeltas,
              let terminal = terminalView(under: event)
        else { return false }
        terminal.sendMouseScroll(
            x: event.scrollingDeltaX * preciseMultiplier,
            y: event.scrollingDeltaY * preciseMultiplier,
            mods: scrollMods(precise: true, phase: event.momentumPhase)
        )
        return true
    }

    /// Ghostty's momentum value for `phase`, mapped exactly as Ghostty.app's
    /// `Ghostty.Input.Momentum` does. The package's own
    /// `TerminalScrollModifiers.Momentum` stops at `.changed`, collapsing
    /// `.ended`/`.cancelled`/`.mayBegin` to none, so the full set is built
    /// here and packed by `scrollMods(precise:phase:)`. Values are
    /// Ghostty's `input.mouse.Momentum` (`enum(u3)` in `src/input/mouse.zig`).
    static func momentum(for phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    /// Ghostty's `ScrollMods` `packed struct(u8)`: bit 0 `precision`, bits
    /// 1–3 `momentum`, rest padding.
    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> TerminalScrollModifiers {
        TerminalScrollModifiers(rawValue: (precise ? 1 : 0) | momentum(for: phase) << 1)
    }

    private static func terminalView(under event: NSEvent) -> TerminalView? {
        guard let window = event.window else { return nil }
        return terminalView(in: window, at: event.locationInWindow)
    }

    /// The terminal view at `locationInWindow`, if any — the view itself or
    /// an ancestor of whatever subview the point hits.
    static func terminalView(in window: NSWindow, at locationInWindow: NSPoint) -> TerminalView? {
        guard let contentView = window.contentView else { return nil }
        // `hitTest` takes a point in the receiver's superview's coordinates.
        let point = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        var view = contentView.hitTest(point)
        while let current = view {
            if let terminal = current as? TerminalView { return terminal }
            view = current.superview
        }
        return nil
    }
}
