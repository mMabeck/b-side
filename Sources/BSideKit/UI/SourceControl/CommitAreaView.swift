import SwiftUI

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

        // Cmd+Return only with the field focused: a global shortcut would fire anywhere in the sidebar or steal Ghostty's keys, so it's not in `appOwnedKeybinds`.
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
