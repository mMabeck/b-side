import GhosttyTheme
import SwiftUI

/// A category sidebar rather than tabs: a tab bar's overflow menu items are disabled at this many panes.
public struct SettingsView: View {
    @ObservedObject private var theme = GhosttyResolvedTheme.shared
    @State private var selection: SettingsPane? = .general

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = selection ?? .general
            detail(for: pane)
                .navigationTitle(pane.title)
        }
        .frame(width: 920, height: 600)
        .themedWindow(theme.palette)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsTab()
        case .appearance: AppearanceSettingsTab(theme: theme)
        case .agent: AgentSettingsTab()
        case .titles: TitleGenerationSettingsTab()
        case .git: GitSettingsTab()
        case .terminal: TerminalSettingsTab()
        case .keybindings: KeybindingsSettingsTab(theme: theme)
        case .notifications: NotificationsSettingsTab(theme: theme)
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, agent, titles, git, terminal, keybindings, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .agent: "Agent"
        case .titles: "Titles"
        case .git: "Git"
        case .terminal: "Terminal"
        case .keybindings: "Keybindings"
        case .notifications: "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .agent: "cpu"
        case .titles: "character.cursor.ibeam"
        case .git: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .keybindings: "keyboard"
        case .notifications: "bell"
        }
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AppearanceSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @AppStorage(AppearanceSettingsKeys.mode) private var modeRaw = ThemeOverrideMode.useConfig.rawValue
    @AppStorage(AppearanceSettingsKeys.singleThemeName) private var singleThemeName = ""

    private var mode: ThemeOverrideMode {
        ThemeOverrideMode(rawValue: modeRaw) ?? .useConfig
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: {
                let name = switch mode {
                case .useConfig: theme.definition?.name ?? ""
                case .single: singleThemeName
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
                }
                GhosttyThemeController.reapply()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Picker("Theme Source", selection: $modeRaw) {
                    ForEach(ThemeOverrideMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .fixedSize()
                .onChange(of: modeRaw) { _, _ in GhosttyThemeController.reapply() }
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                ThemeList(selection: listSelection)
                    .frame(width: 220)

                VStack(alignment: .leading, spacing: 8) {
                    previewContent
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewedDefinition: GhosttyThemeDefinition? {
        switch mode {
        case .useConfig: theme.definition
        case .single: ThemeCatalogSource.theme(named: singleThemeName)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let definition = previewedDefinition {
            ThemePreviewView(definition: definition, scale: 1.2)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4]))
                .frame(width: ThemePreviewView.baseSize.width * 1.2, height: ThemePreviewView.baseSize.height * 1.2)
                .overlay(Text("Pick a theme to preview it.").foregroundStyle(theme.palette.textSecondary))
        }
    }

    private var caption: String {
        switch mode {
        case .useConfig:
            "Following ~/.config/ghostty/config (\(theme.definition?.name ?? "no theme — system colours")). Pick a theme to override it."
        case .single:
            "Use ↑ and ↓ to try themes. Changes apply immediately, including open terminals."
        }
    }
}

private struct AgentSettingsTab: View {
    @AppStorage("settings.agent.defaultHarness") private var defaultHarness = "claude"

    var body: some View {
        Form {
            TextField("Default Harness", text: $defaultHarness)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct GitSettingsTab: View {
    @AppStorage("settings.git.defaultBaseRef") private var defaultBaseRef = "main"

    var body: some View {
        Form {
            TextField("Default Base Ref", text: $defaultBaseRef)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TerminalSettingsTab: View {
    @AppStorage("settings.terminal.fontSize") private var fontSize = 13.0

    var body: some View {
        Form {
            Stepper("Font Size: \(Int(fontSize))", value: $fontSize, in: 9...24)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct KeybindingsSettingsTab: View {
    var theme: GhosttyResolvedTheme
    @State private var query = ""

    private var filteredSections: [KeybindingSection] {
        guard !query.isEmpty else { return KeybindingsReference.sections }
        return KeybindingsReference.sections.compactMap { section in
            let rows = section.rows.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return rows.isEmpty ? nil : KeybindingSection(title: section.title, rows: rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter Shortcuts", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            List {
                ForEach(filteredSections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            LabeledContent(row.title) {
                                Text(row.symbols)
                                    .foregroundStyle(theme.palette.textSecondary)
                                    .accessibilityLabel(row.accessibilityLabel)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Text("Ghostty's own terminal keybinds apply otherwise.")
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
