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
        .frame(width: 480, height: 300)
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
    @AppStorage("settings.notifications.enabled") private var notificationsEnabled = true

    var body: some View {
        Form {
            Toggle("Enable Notifications", isOn: $notificationsEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.windowBackground)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
