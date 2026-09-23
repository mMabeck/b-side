import SwiftUI

/// Standard macOS `Settings` scene content: General, Agent, Git, Terminal, Notifications.
public struct SettingsView: View {
    @ObservedObject private var theme = GhosttyResolvedTheme.shared

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsTab(theme: theme)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab(theme: theme)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AgentSettingsTab(theme: theme)
                .tabItem { Label("Agent", systemImage: "cpu") }
            GitSettingsTab(theme: theme)
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            TerminalSettingsTab(theme: theme)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            NotificationsSettingsTab(theme: theme)
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        // No shared frame: each tab sets its own size, and the Settings
        // window resizes per tab like standard macOS preference panes.
        .background(theme.palette.windowBackground)
        .themedWindow(theme.palette)
    }
}

private struct GeneralSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(width: 480, height: 420, alignment: .top)
    }
}

private struct AppearanceSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage(AppearanceSettingsKeys.mode) private var modeRaw = ThemeOverrideMode.useConfig.rawValue
    @AppStorage(AppearanceSettingsKeys.singleThemeName) private var singleThemeName = ""
    @AppStorage(AppearanceSettingsKeys.lightThemeName) private var lightThemeName = ""
    @AppStorage(AppearanceSettingsKeys.darkThemeName) private var darkThemeName = ""

    private var mode: ThemeOverrideMode {
        ThemeOverrideMode(rawValue: modeRaw) ?? .useConfig
    }

    /// Which slot the theme list edits in ``ThemeOverrideMode/matchSystem``.
    @State private var editingDark = true

    /// The theme list's selection, routed to whichever stored name the
    /// current mode uses. Picking a theme while following the Ghostty
    /// config switches to a single-theme override.
    private var listSelection: Binding<String?> {
        Binding(
            get: {
                let name = switch mode {
                case .useConfig: theme.definition?.name ?? ""
                case .single: singleThemeName
                case .matchSystem: editingDark ? darkThemeName : lightThemeName
                }
                return name.isEmpty ? nil : name
            },
            set: { newValue in
                guard let newValue else { return }
                switch mode {
                case .useConfig:
                    singleThemeName = newValue
                    modeRaw = ThemeOverrideMode.single.rawValue
                case .single:
                    singleThemeName = newValue
                case .matchSystem:
                    if editingDark { darkThemeName = newValue } else { lightThemeName = newValue }
                }
                GhosttyThemeController.reapply()
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ThemeList(selection: listSelection)
                .frame(width: 220)
            Divider()
            Form {
                Section {
                    Picker("Theme Source", selection: $modeRaw) {
                        ForEach(ThemeOverrideMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: modeRaw) { _, _ in GhosttyThemeController.reapply() }

                    switch mode {
                    case .useConfig:
                        LabeledContent("Resolved Theme") {
                            Text(theme.definition?.name ?? "none (system colours)")
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    case .single:
                        LabeledContent("Theme", value: singleThemeName.isEmpty ? "—" : singleThemeName)
                    case .matchSystem:
                        Picker("List Edits", selection: $editingDark) {
                            Text("Light").tag(false)
                            Text("Dark").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Preview") {
                    previewContent
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(theme.palette.windowBackground)
        .frame(width: 720, height: 460)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch mode {
        case .useConfig:
            if let definition = theme.definition {
                ThemePreviewView(definition: definition)
            } else {
                Text("No theme resolved from the Ghostty config — using system colours.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        case .single:
            if let definition = ThemeCatalogSource.theme(named: singleThemeName) {
                ThemePreviewView(definition: definition)
            } else {
                Text("Pick a theme from the list to preview it.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        case .matchSystem:
            HStack(alignment: .top, spacing: 12) {
                previewColumn(title: "Light", themeName: lightThemeName)
                previewColumn(title: "Dark", themeName: darkThemeName)
            }
        }
    }

    @ViewBuilder
    private func previewColumn(title: String, themeName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            if let definition = ThemeCatalogSource.theme(named: themeName) {
                ThemePreviewView(definition: definition, scale: 0.52)
            } else {
                Text("Pick a theme from the list to preview it.")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
    }
}

private struct AgentSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage("settings.agent.defaultHarness") private var defaultHarness = "claude"

    var body: some View {
        Form {
            TextField("Default Harness", text: $defaultHarness)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(width: 480, height: 420, alignment: .top)
    }
}

private struct GitSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage("settings.git.defaultBaseRef") private var defaultBaseRef = "main"

    var body: some View {
        Form {
            TextField("Default Base Ref", text: $defaultBaseRef)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(width: 480, height: 420, alignment: .top)
    }
}

private struct TerminalSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage("settings.terminal.fontSize") private var fontSize = 13.0

    var body: some View {
        Form {
            Stepper("Font Size: \(Int(fontSize))", value: $fontSize, in: 9...24)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(width: 480, height: 420, alignment: .top)
    }
}

private struct NotificationsSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage(TaskAlertSettingsKeys.enabled) private var notificationsEnabled = true
    @AppStorage(TaskAlertSettingsKeys.soundsEnabled) private var playSounds = true
    @AppStorage(TaskAlertSettingsKeys.finishedSound) private var finishedSoundName = TaskAlertSound.defaultFinished.rawValue
    @AppStorage(TaskAlertSettingsKeys.questionSound) private var questionSoundName = TaskAlertSound.defaultQuestion.rawValue
    @AppStorage(TaskAlertSettingsKeys.volume) private var volume = 70.0

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)
            }

            Section("Sounds") {
                Toggle("Play Sounds", isOn: $playSounds)

                Group {
                    Picker("Finished Sound", selection: $finishedSoundName) {
                        ForEach(TaskAlertSound.allCases) { sound in
                            Text(sound.rawValue).tag(sound.rawValue)
                        }
                    }
                    .onChange(of: finishedSoundName) { _, newValue in
                        TaskAlertSound(rawValue: newValue)?.play(volume: volume)
                    }

                    Button("Test") {
                        TaskAlertSound(rawValue: finishedSoundName)?.play(volume: volume)
                    }
                    .disabled(finishedSoundName == TaskAlertSound.off.rawValue)

                    Picker("Question Sound", selection: $questionSoundName) {
                        ForEach(TaskAlertSound.allCases) { sound in
                            Text(sound.rawValue).tag(sound.rawValue)
                        }
                    }
                    .onChange(of: questionSoundName) { _, newValue in
                        TaskAlertSound(rawValue: newValue)?.play(volume: volume)
                    }

                    Button("Test") {
                        TaskAlertSound(rawValue: questionSoundName)?.play(volume: volume)
                    }
                    .disabled(questionSoundName == TaskAlertSound.off.rawValue)

                    VStack(alignment: .leading) {
                        Text("Volume: \(Int(volume))%")
                            .font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                        Slider(value: $volume, in: 0...100, step: 1)
                    }
                }
                .disabled(!playSounds)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(width: 480, height: 420, alignment: .top)
    }
}
