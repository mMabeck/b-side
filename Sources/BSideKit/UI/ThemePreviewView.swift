import GhosttyTheme
import SwiftUI

/// A tiny, pure-SwiftUI mock of "Pi in B-Side" rendered in a given theme —
/// no real terminal grid, just static text and shapes coloured from the
/// theme's own palette. Used by the Appearance tab so picking a theme shows
/// roughly what it will look like without committing to it first.
public struct ThemePreviewView: View {
    static let baseSize = CGSize(width: 360, height: 200)

    let definition: GhosttyThemeDefinition
    let palette: BSidePalette
    /// Shrinks the whole mock uniformly (e.g. for a side-by-side light/dark
    /// pair) while keeping every internal layout proportion identical to the
    /// full-size preview.
    var scale: CGFloat = 1

    public init(definition: GhosttyThemeDefinition, scale: CGFloat = 1) {
        self.definition = definition
        self.scale = scale
        palette = BSidePalette.themed(from: definition)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                mainArea
            }
            drawer
        }
        .frame(width: Self.baseSize.width, height: Self.baseSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.separator, lineWidth: 1))
        .scaleEffect(scale)
        .frame(width: Self.baseSize.width * scale, height: Self.baseSize.height * scale)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(definition.name)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            taskRow(color: palette.statusRunning, label: "task/alpha")
            taskRow(color: palette.statusNeedsAttention, label: "task/beta")
            taskRow(color: palette.statusSuccess, label: "task/gamma")
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 92, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(palette.surfaceBackground)
    }

    private func taskRow(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Main area: mock Pi TUI

    private var mainArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            monoLine("❯ summarize this diff", color: ansi(7) ?? palette.textPrimary)
            monoLine("Looks good, two small notes below.", color: ansi(15) ?? palette.textPrimary)
            monoLine("✓ read Sources/App.swift", color: ansi(2) ?? palette.statusSuccess)
            inputBox
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(background)
    }

    private var inputBox: some View {
        HStack(spacing: 0) {
            Text("> ask pi anything")
                .foregroundStyle((ansi(8) ?? palette.textSecondary))
            Rectangle()
                .fill(cursorColor)
                .frame(width: 6, height: 11)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.separator, lineWidth: 1))
    }

    // MARK: - Drawer: mock shell prompt

    private var drawer: some View {
        HStack(spacing: 5) {
            Text("~/project").foregroundStyle(ansi(4) ?? palette.textPrimary)
            Text("main").foregroundStyle(ansi(5) ?? palette.textPrimary)
            Text("❯").foregroundStyle(ansi(2) ?? palette.statusSuccess)
            Text("git status").foregroundStyle(foreground)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceBackground)
    }

    // MARK: - Colour helpers

    private func monoLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var background: Color { RGBColor(hex: definition.background).color }
    private var foreground: Color { RGBColor(hex: definition.foreground).color }

    private var cursorColor: Color {
        definition.cursorColor.map { RGBColor(hex: $0).color } ?? palette.accent
    }

    private func ansi(_ index: Int) -> Color? {
        definition.palette[index].map { RGBColor(hex: $0).color }
    }
}
