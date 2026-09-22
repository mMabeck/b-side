import SwiftUI

/// Standard macOS `Settings` scene content: General, Agent, Git, Terminal, Notifications.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentSettingsTab()
                .tabItem { Label("Agent", systemImage: "cpu") }
            GitSettingsTab()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 420, height: 240)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
        }
        .padding(20)
    }
}

private struct AgentSettingsTab: View {
    @AppStorage("settings.agent.defaultHarness") private var defaultHarness = "claude"

    var body: some View {
        Form {
            TextField("Default Harness", text: $defaultHarness)
        }
        .padding(20)
    }
}

private struct GitSettingsTab: View {
    @AppStorage("settings.git.defaultBaseRef") private var defaultBaseRef = "main"

    var body: some View {
        Form {
            TextField("Default Base Ref", text: $defaultBaseRef)
        }
        .padding(20)
    }
}

private struct TerminalSettingsTab: View {
    @AppStorage("settings.terminal.fontSize") private var fontSize = 13.0

    var body: some View {
        Form {
            Stepper("Font Size: \(Int(fontSize))", value: $fontSize, in: 9...24)
        }
        .padding(20)
    }
}

private struct NotificationsSettingsTab: View {
    @AppStorage("settings.notifications.enabled") private var notificationsEnabled = true

    var body: some View {
        Form {
            Toggle("Enable Notifications", isOn: $notificationsEnabled)
        }
        .padding(20)
    }
}
