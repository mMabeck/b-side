import SwiftUI

/// The Push button, or (while a push is running) a scrolling monospaced
/// output log and a Cancel button in its place — mirrors `CommitAreaView`.
/// Hidden entirely by the caller when the task's worktree has no `origin`.
struct PushAreaView: View {
    let aheadCount: Int?
    let isPushing: Bool
    let canPush: Bool
    let log: [String]
    let palette: BSidePalette
    let onPush: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPushing {
                pushLogView
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textSecondary)
            } else {
                Button(action: onPush) {
                    Label(pushTitle, systemImage: "arrow.up.circle")
                }
                .buttonStyle(.glass)
                .tint(palette.accent)
                .disabled(!canPush)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(aheadCount.map { "Push, \($0) commit\($0 == 1 ? "" : "s") ahead" } ?? "Push")
            }
        }
        .padding(10)
    }

    private var pushTitle: String {
        guard let aheadCount, aheadCount > 0 else { return "Push" }
        return "Push \u{2191}\(aheadCount)"
    }

    private var pushLogView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                            .id(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(height: 90)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.elevatedSurfaceBackground)
            )
            .onChange(of: log.count) { _, _ in
                guard let last = log.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .accessibilityLabel("Push output")
        }
    }
}
