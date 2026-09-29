import AppKit
import SwiftUI

struct TitleGenerationSettingsTab: View {
    private typealias Keys = TitleGenerationSettings.Keys

    @AppStorage(Keys.mode) private var modeRaw = TitleGenerationMode.localModel.rawValue
    @AppStorage(Keys.claudeModel) private var claudeModel = TitleGenerationSettings.defaultClaudeModel
    @AppStorage(Keys.codexModel) private var codexModel = ""
    @AppStorage(Keys.modelSource) private var sourceRaw = TitleModelSource.file.rawValue
    @AppStorage(Keys.huggingFaceRepo) private var huggingFaceRepo = TitleGenerationSettings.defaultHuggingFaceRepo
    @AppStorage(Keys.huggingFaceQuant) private var huggingFaceQuant = TitleGenerationSettings.defaultHuggingFaceQuant
    @AppStorage(Keys.modelFilePath) private var modelFilePath = TitleGenerationSettings.defaultModelFilePath

    @ObservedObject private var downloader = TitleModelDownloader.shared
    @State private var samplePrompt = "the login page throws a 500 error, please fix it"
    @State private var testResult: Result<String, TitleGenerationFailure>?
    @State private var isTesting = false

    private var mode: TitleGenerationMode { TitleGenerationMode(rawValue: modeRaw) ?? .localModel }
    private var source: TitleModelSource { TitleModelSource(rawValue: sourceRaw) ?? .file }

    var body: some View {
        Form {
            Section {
                Picker("Generate Titles With", selection: $modeRaw) {
                    ForEach(TitleGenerationMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text(LocalizedStringKey(footer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch mode {
            case .firstWords:
                EmptyView()
            case .claude:
                Section("Claude") {
                    BinaryStatusRow(name: "claude")
                    TextField("Model", text: $claudeModel, prompt: Text(TitleGenerationSettings.defaultClaudeModel))
                }
            case .codex:
                Section("Codex") {
                    BinaryStatusRow(name: "codex")
                    TextField("Model", text: $codexModel, prompt: Text("Codex default"))
                }
            case .localModel:
                localModelSection
            }

            if mode != .firstWords {
                testSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480, alignment: .top)
        .onChange(of: modeRaw) { testResult = nil }
    }

    private var footer: String {
        switch mode {
        case .firstWords: "Titles are the first words of the prompt. Nothing leaves this Mac."
        case .claude: "Sends the first prompt to Claude through the `claude` CLI and your existing login."
        case .codex: "Sends the first prompt to OpenAI through the `codex` CLI and your existing login."
        case .localModel: "Runs a GGUF model on this Mac with llama.cpp's `llama-completion`."
        }
    }

    @ViewBuilder
    private var localModelSection: some View {
        Section("Local Model") {
            BinaryStatusRow(name: "llama-completion", installHint: "brew install llama.cpp")
            Picker("Source", selection: $sourceRaw) {
                ForEach(TitleModelSource.allCases) { source in
                    Text(source.label).tag(source.rawValue)
                }
            }
            .pickerStyle(.segmented)

            switch source {
            case .huggingFace:
                TextField("Repository", text: $huggingFaceRepo, prompt: Text("owner/name"))
                TextField("Quant", text: $huggingFaceQuant, prompt: Text("Q8_0"))
                downloadRow
            case .file:
                LabeledContent("Model File") {
                    HStack {
                        TextField("Model File", text: $modelFilePath)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseModelFile)
                    }
                }
                if !modelExists {
                    Label("File not found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        LabeledContent("Status") {
            switch downloader.state {
            case .downloading(let fraction):
                HStack {
                    if let fraction {
                        ProgressView(value: fraction)
                            .frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { downloader.cancel() }
                }
            case .idle, .failed:
                HStack {
                    Text(modelExists ? "Downloaded" : "Not downloaded")
                        .foregroundStyle(.secondary)
                    Button(modelExists ? "Download Again" : "Download") {
                        downloader.download(repo: huggingFaceRepo, quant: huggingFaceQuant)
                    }
                    .disabled(huggingFaceRepo.isEmpty || huggingFaceQuant.isEmpty)
                }
            }
        }
        if case .failed(let message) = downloader.state {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var testSection: some View {
        Section("Test") {
            TextField("Prompt", text: $samplePrompt)
            LabeledContent("Title") {
                HStack {
                    switch testResult {
                    case nil:
                        EmptyView()
                    case .success(let title):
                        Text(title).textSelection(.enabled)
                    case .failure(let failure):
                        Text(failure.description)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Generate", action: runTest)
                        .disabled(isTesting || samplePrompt.isEmpty)
                }
            }
        }
    }

    private var modelExists: Bool {
        _ = downloader.state  // re-check after a download finishes
        return FileManager.default.fileExists(atPath: TitleGenerationSettings.load().localModelURL.path)
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let prompt = samplePrompt
        let settings = TitleGenerationSettings.load()
        Task {
            testResult = await TaskTitleGenerator.generateResult(fromPrompt: prompt, settings: settings)
            isTesting = false
        }
    }

    private func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (modelFilePath as NSString).expandingTildeInPath)
            .deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelFilePath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct BinaryStatusRow: View {
    let name: String
    var installHint: String?

    var body: some View {
        LabeledContent {
            if let path = TaskTitleGenerator.resolveBinary(named: name) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Label(installHint.map { "Not found — \($0)" } ?? "Not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(name).monospaced()
        }
    }
}
