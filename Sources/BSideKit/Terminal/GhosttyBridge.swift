import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import OSLog
import SwiftUI

/// The only file that may import libghostty: its embedding API is unstable upstream.
/// Uses the SwiftUI surface, never `TerminalSurfaceViewDelegate`, so unhandled actions fall back to Ghostty's defaults (links: ``TerminalLinkOpener``).
public enum GhosttyBridge {
    static let logger = Logger(subsystem: "dev.mabeck.bside", category: "terminal-theme")

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

    /// Adaptive `light:X,dark:Y` always resolves to `dark`: appearance is never derived from macOS.
    enum ThemeDirective: Equatable {
        case fixed(String)
        case adaptive(light: String, dark: String)
    }

    /// libghostty-spm rejects the whole config if `theme = <name>` fails to resolve, so the theme line is pulled out
    /// and reapplied as colour directives.
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

        // Malformed (missing a side) falls through as a literal name so fallback logging names the bad value.
        guard let light, let dark else { return .fixed(value) }
        return .adaptive(light: light, dark: dark)
    }

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

    /// Colours travel through `theme:`, not `terminalConfiguration:`: `TerminalController` renders the theme layer last and overwrites them.
    struct ResolvedUserConfig {
        let configSource: TerminalController.ConfigSource
        let theme: TerminalTheme
        let themeDefinition: GhosttyThemeDefinition?
    }

    /// Unbound so the terminal surface doesn't swallow app shortcuts before AppKit's menu (`performKeyEquivalent` runs first).
    /// Add any new app shortcut colliding with a Ghostty default here; an unbind alone fails under Pi's kitty keyboard mode.
    /// Copy/paste/select-all/find stay bound to the terminal deliberately.
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
    keybind = cmd+shift+u=unbind
    \(digitUnbinds)

    """

    private static let digitUnbinds: String = (1...9)
        .flatMap { digit in ["keybind = cmd+\(digit)=unbind", "keybind = ctrl+\(digit)=unbind"] }
        .joined(separator: "\n")

    @MainActor
    static func resolveUserConfig(
        override: ThemeDirective? = ThemeOverride.currentDirective()
    ) -> ResolvedUserConfig {
        guard let path = userConfigFilePath else {
            // Generated, not `.none`: app key equivalents must be unbound regardless.
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
        let directive = override ?? configDirective
        // Generated, not `.file(path)`: the unbinds must be appended either way.
        let definition = resolveThemeDefinition(directive)
        let theme = definition?.toTerminalTheme() ?? .default
        return ResolvedUserConfig(
            configSource: .generated(sanitized + appOwnedKeybinds),
            theme: theme,
            themeDefinition: definition
        )
    }
}

/// `definition` is `nil` until resolved: no opinion, use system colours.
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

    /// Called at launch so windows with no terminal (Settings, New Task) see the real theme on first frame.
    public static func resolveEagerly(into target: GhosttyResolvedTheme = shared) {
        target.update(GhosttyBridge.resolveUserConfig().themeDefinition)
    }

    public var palette: BSidePalette {
        definition.map(BSidePalette.themed(from:)) ?? .fallback
    }
}

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

    /// `onExit` fires only when the process exits on its own, not on explicit teardown.
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

        // `.at` publishes last, so reading `state` here yields the fully updated triple, not a stale title with a fresh timestamp.
        state.$lastDesktopNotificationAt
            .compactMap { $0 }
            .sink { [weak self] at in
                guard let self else { return }
                lastDesktopNotificationTitle = state.lastDesktopNotificationTitle
                lastDesktopNotificationBody = state.lastDesktopNotificationBody
                lastDesktopNotificationAt = at
            }
            .store(in: &cancellables)

        TerminalSurfaceHostRegistry.shared.register(self)
    }

    deinit {
        // `deinit` runs nonisolated; safe because the registry is only touched from the main actor.
        MainActor.assumeIsolated {
            TerminalSurfaceHostRegistry.shared.unregister(self)
        }
    }

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

    /// Replays once attached; see ``TerminalHostView`` for why focus is driven imperatively.
    public func focus() {
        state.requestFocus()
    }

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

    /// Bracketed paste, so embedded newlines land in the edit line instead of running.
    @discardableResult
    public func paste(_ text: String) -> Bool {
        state.paste(text: text)
    }

    @discardableResult
    public func sendReturn() -> Bool {
        state.sendKey(.enter)
    }
}

/// Deliberately not bound to `@FocusState`: SwiftUI resets an unanchored one to nil on re-render, stealing focus from the terminal.
public struct TerminalHostView: View {
    @ObservedObject var host: TerminalSurfaceHost

    public init(host: TerminalSurfaceHost) {
        self.host = host
    }

    public var body: some View {
        TerminalSurfaceView(context: host.state)
    }
}

/// In-memory surface (no pty) for the subagent strip: clicks arrive via `onHostInput` as raw SGR reports, since
/// `InMemoryTerminalSession.write` fires wherever Ghostty would write to a pty's stdin.
@MainActor
public final class SubagentStripHost: ObservableObject {
    public let hostView: TerminalSurfaceHost
    private let session: InMemoryTerminalSession

    public var onHostInput: ((Data) -> Void)?

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

    /// Skips unchanged frames: every repaint wakes libghostty's display link.
    public func render(lines: [String]) {
        guard lines != lastRenderedLines else { return }
        lastRenderedLines = lines
        let body = (["\u{1B}[H\u{1B}[2J\u{1B}[?25l"] + lines).joined(separator: "\r\n")
        session.receive(body)
    }

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
    /// Spawning many real exec surfaces back-to-back crashes libghostty under `swift test`.
    static func makeInMemoryForTesting() -> TerminalSurfaceHost {
        TerminalSurfaceHost(inMemorySession: InMemoryTerminalSession(write: { _ in }, resize: { _ in }))
    }
}

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

    func applyThemeToAllHosts(_ theme: TerminalTheme) {
        for box in hosts.values {
            box.host?.state.setTheme(theme)
        }
    }
}

@MainActor
public enum GhosttyThemeController {
    static func reapply() {
        let resolved = GhosttyBridge.resolveUserConfig()
        GhosttyResolvedTheme.shared.update(resolved.themeDefinition)
        NSApplication.shared.appearance = GhosttyResolvedTheme.shared.palette.preferredAppearance
        TerminalSurfaceHostRegistry.shared.applyThemeToAllHosts(resolved.theme)
    }
}

/// Mounted for every cached host, live or hidden, so a background task's alert still fires.
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

/// libghostty-spm forwards raw precise-scroll deltas while Ghostty.app doubles them; the view can't be subclassed,
/// so a local monitor resends doubled deltas.
@MainActor
public enum TerminalScrollRouter {
    static let preciseMultiplier: Double = 2

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

    /// The package's `TerminalScrollModifiers.Momentum` stops at `.changed`; this mirrors Ghostty's full `input.mouse.Momentum`.
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

/// Ghostty's fallback opener refuses OSC 8 hyperlinks (`UnsafeOSC8Link`), so without this Pi's links do nothing.
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

    /// An OSC 8 link's text needn't match its target, so a local file that would run something is revealed in Finder.
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
