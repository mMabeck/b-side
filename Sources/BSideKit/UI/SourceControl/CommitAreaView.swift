import SwiftUI

/// The commit message field and commit button, or (while a commit is
/// running) a scrolling monospaced hook-output log and a Cancel button in
/// their place. The log stays visible after a failed commit — it isn't
/// cleared until the next commit attempt starts.
struct CommitAreaView: View {
    @Binding var message: String
    let isCommitting: Bool
    let log: [String]
    let canCommit: Bool
    let palette: BSidePalette
    let isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCommitting {
                commitLogView
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.textSecondary)
            } else {
                TextField("Message", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .font(.system(size: 12))
                    .focused(isFocused)

                commitButton
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var commitButton: some View {
        let button = Button("Commit", action: onCommit)
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .disabled(!canCommit)
            .frame(maxWidth: .infinity, alignment: .trailing)

        // ⌘↩ commits only while the message field itself has focus — a
        // global shortcut here would fire from anywhere in the sidebar
        // (or steal the key from Ghostty's own terminal panes), so it is
        // deliberately not added to `GhosttyBridge.appOwnedKeybinds`.
        if isFocused.wrappedValue {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }

    private var commitLogView: some View {
        GroupBox {
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
                }
                .onChange(of: log.count) { _, _ in
                    guard let last = log.indices.last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(height: 90)
        .accessibilityLabel("Commit output")
    }
}
