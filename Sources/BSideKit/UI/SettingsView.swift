import SwiftUI

/// Standard macOS `Settings` scene content: General, Agent, Git, Terminal, Notifications.
public struct SettingsView: View {
    @ObservedObject private var theme = GhosttyResolvedTheme.shared

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsTab(theme: theme)
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentSettingsTab(theme: theme)
                .tabItem { Label("Agent", systemImage: "cpu") }
            GitSettingsTab(theme: theme)
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            TerminalSettingsTab(theme: theme)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            NotificationsSettingsTab(theme: theme)
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 480, height: 420)
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
        .frame(maxHeight: .infinity, alignment: .top)
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
        .frame(maxHeight: .infinity, alignment: .top)
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
        .frame(maxHeight: .infinity, alignment: .top)
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
        .frame(maxHeight: .infinity, alignment: .top)
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
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
