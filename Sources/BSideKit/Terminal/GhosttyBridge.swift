import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import OSLog
import SwiftUI

/// The single seam between BSideKit and libghostty: no other file may import
/// `GhosttyKit`/`GhosttyTerminal`, since the embedding
/// API is unstable upstream. Uses the SwiftUI surface (`TerminalSurfaceView`
/// + `TerminalViewState`), never `TerminalSurfaceViewDelegate` — so this app
/// never falsely claims to have handled an action (title, close, bell,
/// desktop notification, ...) it hasn't; unhandled events fall back to
/// Ghostty's own default behaviour. The one exception is opening links: see
/// ``TerminalLinkOpener``.
public enum GhosttyBridge {
    static let logger = Logger(subsystem: "dev.mabeck.bside", category: "terminal-theme")

    /// Respects `XDG_CONFIG_HOME`, falling back to `~/.config/ghostty/config`.
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

    /// One `theme = ...` directive: a fixed name, or `light:X,dark:Y`. B-Side
    /// never derives appearance from macOS, so adaptive always resolves to
    /// `dark` — see ``resolveThemeDefinition(_:)``.
    enum ThemeDirective: Equatable {
        case fixed(String)
        case adaptive(light: String, dark: String)
    }

    /// `libghostty-spm` rejects the *entire* config if `theme = <name>` fails
    /// to resolve, even against this package's own catalog. This pulls the `theme` line out before libghostty sees it and
    /// reapplies it as individual colour directives once resolved; everything
    /// else in the file passes through untouched.
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
            // Dropped here; its colours are reapplied programmatically once resolved.
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

        // Malformed (missing one side) falls through as a literal name so the
        // fallback logging below can still name the actual bad value.
        guard let light, let dark else { return .fixed(value) }
        return .adaptive(light: light, dark: dark)
    }

    /// Never throws: an unresolvable name is logged and `nil` returned so the
    /// caller falls back to the default theme. Adaptive directives always
    /// resolve to `dark`.
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

    /// The user's config, fully resolved for ``GhosttyResolvedTheme`` to publish.
    /// Colours travel through `theme:`, not `terminalConfiguration:` —
    /// `TerminalController` always renders the theme layer last, so colours
    /// placed in `terminalConfiguration` get silently overwritten.
    struct ResolvedUserConfig {
        let configSource: TerminalController.ConfigSource
        let theme: TerminalTheme
        let themeDefinition: GhosttyThemeDefinition?
    }

    /// Key equivalents this app owns, unbound here so the terminal surface
    /// doesn't swallow them before AppKit's menu ever sees the key
    /// (`performKeyEquivalent` runs before the main menu). Each entry mirrors
    /// an app shortcut colliding with a Ghostty default: `cmd+,`→open_config,
    /// `cmd+1…9`/`ctrl+1…9`→goto_tab, `cmd+q`→quit, `cmd+w`→close_surface,
    /// `cmd+n`→new_window, `cmd+shift+r`(near `cmd+r`→reload_config), and
    /// `cmd+shift+d`→new_split:down (would otherwise swallow "Show All
    /// Changes"). A new colliding app shortcut must be added here too — an
    /// unbind alone under Pi's kitty keyboard mode isn't enough. Copy/paste/
    /// select-all/find stay bound to the terminal deliberately.
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

    /// One `keybind = …=unbind` per digit 1–9, for `cmd+` and `ctrl+`.
    private static let digitUnbinds: String = (1...9)
        .flatMap { digit in ["keybind = cmd+\(digit)=unbind", "keybind = ctrl+\(digit)=unbind"] }
        .joined(separator: "\n")

    /// `override` (defaulting to the live Appearance-tab preference) replaces
    /// whatever `theme = ...` directive the config has, if any; tests can
    /// pass an explicit value to keep resolution pure.
    @MainActor
    static func resolveUserConfig(
        override: ThemeDirective? = ThemeOverride.currentDirective()
    ) -> ResolvedUserConfig {
        guard let path = userConfigFilePath else {
            // Generated rather than `.none`: the app's own key equivalents
            // must be released from Ghostty's defaults regardless.
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
            // Logged since this silently falls back to the default theme otherwise.
            logger.error("ghostty config: failed to read \(path, privacy: .public): \(error, privacy: .public)")
            let definition = resolveThemeDefinition(override)
            return ResolvedUserConfig(
                configSource: .generated(appOwnedKeybinds),
                theme: definition?.toTerminalTheme() ?? .default,
                themeDefinition: definition
            )
        }

        let (sanitized, configDirective) = extractThemeDirective(from: raw)
        // Override replaces the config file's own directive outright.
        let directive = override ?? configDirective
        // Generated text rather than `.file(path)`, even with no theme
        // directive, since the unbinds must be appended either way.
        let definition = resolveThemeDefinition(directive)
        let theme = definition?.toTerminalTheme() ?? .default
        return ResolvedUserConfig(
            configSource: .generated(sanitized + appOwnedKeybinds),
            theme: theme,
            themeDefinition: definition
        )
    }
}

/// Publishes the Ghostty theme resolved from `~/.config/ghostty/config` so
/// SwiftUI views outside the terminal grid can mirror it. `definition` is
/// `nil` until resolved; treat `nil` as "no opinion, use system colours."
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

    /// Resolves from disk and publishes to `target` (``shared`` by default),
    /// independent of any terminal surface. Called at app launch so windows
    /// with no terminal (Settings, New Task) see the real theme on first
    /// frame. `target` is overridable so tests avoid the shared singleton.
    public static func resolveEagerly(into target: GhosttyResolvedTheme = shared) {
        target.update(GhosttyBridge.resolveUserConfig().themeDefinition)
    }

    /// The app-wide semantic palette, derived from the resolved theme or
    /// ``BSidePalette/fallback`` otherwise.
    public var palette: BSidePalette {
        definition.map(BSidePalette.themed(from:)) ?? .fallback
    }
}

/// One libghostty surface: a real pty running a login shell, owned by the
/// `.exec` backend.
@MainActor
public final class TerminalSurfaceHost: ObservableObject {
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "terminal")

    let state: TerminalViewState

    /// Republished so `TerminalAlertBridge` can observe them without importing `GhosttyTerminal`.
    @Published public private(set) var bellCount: Int = 0
    @Published public private(set) var lastDesktopNotificationTitle: String?
    @Published public private(set) var lastDesktopNotificationBody: String?
    @Published public private(set) var lastDesktopNotificationAt: Date?

    private var cancellables: Set<AnyCancellable> = []

    /// `command`, when given, replaces the default `shell -l`. `onExit` fires
    /// only when the surface's own process exits on its own, not on an
    /// explicit teardown the caller already knows about.
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

        // Registered so a later theme change (``GhosttyThemeController/reapply()``) can re-theme this surface.
        TerminalSurfaceHostRegistry.shared.register(self)
    }

    deinit {
        // `deinit` on a `@MainActor` class runs nonisolated; safe here since
        // the registry's dictionary is only ever touched from the main actor.
        MainActor.assumeIsolated {
            TerminalSurfaceHostRegistry.shared.unregister(self)
        }
    }

    /// Backs a surface with an `InMemoryTerminalSession` instead of a real pty — used only by `SubagentStripHost`.
    fileprivate init(inMemorySession: InMemoryTerminalSession) {
        let resolvedConfig = GhosttyBridge.resolveUserConfig()
        state = TerminalViewState(
            configSource: resolvedConfig.configSource,
            theme: resolvedConfig.theme
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(inMemorySession))
    }

    /// A hidden surface is marked not-visible rather than torn down: grid, scrollback and session persist.
    public var isVisible: Bool {
        get { state.isSurfaceVisible }
        set { state.isSurfaceVisible = newValue }
    }

    public var title: String { state.title }

    /// Replays once the view is attached if it isn't yet. See ``TerminalHostView`` for why focus is driven imperatively.
    public func focus() {
        state.requestFocus()
    }

    /// Lets callers outside this file ask "is a terminal taking keystrokes?" without importing `GhosttyTerminal`.
    public static func isTerminalView(_ responder: NSResponder?) -> Bool {
        responder is TerminalView
    }

    public var hasKeyboardFocus: Bool {
        guard let view = state.attachedPlatformView, let window = view.window else { return false }
        return window.firstResponder === view
    }

    /// Deferred one runloop hop so it lands after any queued `focus()` replay (`requestFocus()` also hops the runloop) instead of being undone by it.
    public func resignFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, hasKeyboardFocus else { return }
            state.attachedPlatformView?.window?.makeFirstResponder(nil)
        }
    }

    /// Framed as a bracketed paste, so embedded newlines land in the edit line instead of running anything. Distinct from ``sendReturn()``.
    @discardableResult
    public func paste(_ text: String) -> Bool {
        state.paste(text: text)
    }

    /// The key path, never paste-framed, unlike ``paste(_:)``.
    @discardableResult
    public func sendReturn() -> Bool {
        state.sendKey(.enter)
    }
}

/// SwiftUI view hosting one `TerminalSurfaceHost`; the only type outside this
/// file that needs a terminal on screen.
///
/// Deliberately not bound to `@FocusState`: SwiftUI resets an unanchored
/// `@FocusState` to nil on its own, so any re-render (title change, bell,
/// ...) could silently steal keyboard focus from the terminal being typed
/// in. Callers move focus with ``TerminalSurfaceHost/focus()``/``resignFocus()`` instead.
public struct TerminalHostView: View {
    @ObservedObject var host: TerminalSurfaceHost

    public init(host: TerminalSurfaceHost) {
        self.host = host
    }

    public var body: some View {
        TerminalSurfaceView(context: host.state)
    }
}

/// One in-memory Ghostty surface rendering the subagent card strip: no pty,
/// no child process. `render(lines:)` writes ANSI bytes directly into the
/// grid; mouse clicks come back through `onHostInput` as raw SGR report
/// bytes (`InMemoryTerminalSession.write` fires wherever Ghostty would
/// otherwise write to a real pty's stdin), which `SubagentStripMouseParser` turns into clicks.
@MainActor
public final class SubagentStripHost: ObservableObject {
    public let hostView: TerminalSurfaceHost
    private let session: InMemoryTerminalSession

    /// SGR mouse reports once ``enableMouseReporting()`` has run. Set by the caller (`SubagentStripView`).
    public var onHostInput: ((Data) -> Void)?

    /// `nil` until the surface first attaches to a real view and reports a viewport.
    @Published public private(set) var latestViewport: InMemoryTerminalViewport? {
        didSet { lastRenderedLines = nil }
    }

    private var lastRenderedLines: [String]?

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

    /// Bytes sent before a real view attaches are buffered and flushed on attach, so this is safe to call right after ``init()``.
    public func enableMouseReporting() {
        session.receive("\u{1B}[?1000h\u{1B}[?1006h")
    }

    /// Full-repaint, not incremental — `SubagentStripRenderer` re-renders everything each tick.
    /// Unchanged frames are skipped: every repaint wakes libghostty's display link.
    public func render(lines: [String]) {
        guard lines != lastRenderedLines else { return }
        lastRenderedLines = lines
        let body = (["\u{1B}[H\u{1B}[2J\u{1B}[?25l"] + lines).joined(separator: "\r\n")
        session.receive(body)
    }

    /// Falls back to an estimate before the surface has reported its first viewport.
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

    /// Lets closures captured before `self` exists reach the fully constructed host.
    private final class HostInputBox: @unchecked Sendable {
        weak var host: SubagentStripHost?
    }
}

extension TerminalSurfaceHost {
    /// For tests that create several panes at once: spawning many real exec surfaces back-to-back crashes libghostty under `swift test`.
    static func makeInMemoryForTesting() -> TerminalSurfaceHost {
        TerminalSurfaceHost(inMemorySession: InMemoryTerminalSession(write: { _ in }, resize: { _ in }))
    }
}

/// Tracks every live ``TerminalSurfaceHost`` so a theme change can reach it
/// without restarting the app. Entries are weak; a closed host stops
/// receiving updates once ``TerminalSurfaceHost/deinit`` unregisters it.
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

    /// `setTheme(_:)` reconfigures the running surface without touching its pty or session.
    func applyThemeToAllHosts(_ theme: TerminalTheme) {
        for box in hosts.values {
            box.host?.state.setTheme(theme)
        }
    }
}

/// Re-resolves the user's config with the Appearance tab's override,
/// republishes it, updates `NSApp`'s appearance immediately, and re-themes
/// every live terminal.
@MainActor
public enum GhosttyThemeController {
    static func reapply() {
        let resolved = GhosttyBridge.resolveUserConfig()
        GhosttyResolvedTheme.shared.update(resolved.themeDefinition)
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance
        TerminalSurfaceHostRegistry.shared.applyThemeToAllHosts(resolved.theme)
    }
}

/// Invisible per-task bridge from `TerminalSurfaceHost`'s republished bell/
/// desktop-notification signals to `ProjectsStore.handleTerminalBell`/
/// `handleTerminalDesktopNotification`, mounted alongside `TerminalHostView`
/// for every cached host — live or hidden — so a background task's alert still fires.
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

/// Makes trackpad scrolling feel like Ghostty.app: `libghostty-spm`'s
/// `AppTerminalView` forwards raw precise-scroll deltas, while Ghostty.app
/// doubles them, so the same config scrolls at half speed here. The view
/// can't be subclassed, so a local monitor intercepts the event and
/// resends the doubled delta through `sendMouseScroll`. Wheel-mouse events pass through untouched.
@MainActor
public enum TerminalScrollRouter {
    static let preciseMultiplier: Double = 2

    /// Call once, from `BSideApp.init()`.
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            route(event) ? nil : event
        }
    }

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

    /// Mirrors Ghostty.app's `Ghostty.Input.Momentum`; the package's own
    /// `TerminalScrollModifiers.Momentum` stops at `.changed`, so the full
    /// set (Ghostty's `input.mouse.Momentum`, `enum(u3)`) is built here instead.
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

    /// Ghostty's `ScrollMods` `packed struct(u8)`: bit 0 `precision`, bits 1–3 `momentum`.
    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> TerminalScrollModifiers {
        TerminalScrollModifiers(rawValue: (precise ? 1 : 0) | momentum(for: phase) << 1)
    }

    private static func terminalView(under event: NSEvent) -> TerminalView? {
        guard let window = event.window else { return nil }
        return terminalView(in: window, at: event.locationInWindow)
    }

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

/// Ghostty's fallback opener refuses OSC 8 hyperlinks (`UnsafeOSC8Link`) and
/// leaves them to the host, so without this Pi's links do nothing on click.
extension TerminalViewState: @retroactive TerminalSurfaceOpenURLDelegate {
    public func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        TerminalLinkOpener.open(url)
    }
}

enum TerminalLinkOpener {
    enum Action: Equatable {
        case open(URL)
        case reveal(URL)
    }

    /// An OSC 8 link's text needn't match its target, so a local file that
    /// would run something is revealed in Finder rather than opened.
    static func action(for link: String, fileManager: FileManager = .default) -> Action? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fileURL: URL
        if let url = URL(string: text), let scheme = url.scheme, scheme.count > 1 {
            guard scheme.lowercased() == "file" else { return .open(url) }
            fileURL = url
        } else if text.hasPrefix("/") || text.hasPrefix("~") {
            fileURL = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        return launchesSomething(fileURL, fileManager: fileManager) ? .reveal(fileURL) : .open(fileURL)
    }

    private static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "workflow", "pkg", "mpkg", "scpt", "applescript",
    ]

    private static func launchesSomething(_ url: URL, fileManager: FileManager) -> Bool {
        if launchingExtensions.contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return NSWorkspace.shared.isFilePackage(atPath: url.path) }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    @MainActor
    static func open(_ link: String) {
        switch action(for: link) {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil:
            GhosttyBridge.logger.info("ignored unopenable link \(link, privacy: .private)")
        }
    }
}
