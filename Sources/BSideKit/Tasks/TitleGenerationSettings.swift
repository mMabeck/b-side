import Foundation

public enum TitleGenerationMode: String, CaseIterable, Identifiable, Sendable {
    case firstWords
    case claude
    case codex
    case localModel

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .firstWords: "First Words of the Prompt"
        case .claude: "Claude CLI"
        case .codex: "Codex CLI"
        case .localModel: "Local Model"
        }
    }
}

public enum TitleModelSource: String, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case file

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .file: "GGUF File"
        }
    }
}

public struct TitleGenerationSettings: Equatable, Sendable {
    public enum Keys {
        public static let mode = "settings.titleGeneration.mode"
        public static let claudeModel = "settings.titleGeneration.claudeModel"
        public static let codexModel = "settings.titleGeneration.codexModel"
        public static let modelSource = "settings.titleGeneration.modelSource"
        public static let huggingFaceRepo = "settings.titleGeneration.huggingFaceRepo"
        public static let huggingFaceQuant = "settings.titleGeneration.huggingFaceQuant"
        public static let modelFilePath = "settings.titleModel.path"
    }

    public static let defaultClaudeModel = "haiku"
    public static let defaultHuggingFaceRepo = "Mabeck/qwen3.5-0.8b-kth8-titles"
    public static let defaultHuggingFaceQuant = "Q8_0"
    public static let defaultModelFilePath = "~/Claude/title-gen/models/gguf/qwen3.5-0.8b-title-Q8_0.gguf"

    public var mode: TitleGenerationMode = .localModel
    public var claudeModel = defaultClaudeModel
    /// Empty means Codex's own configured default model.
    public var codexModel = ""
    public var modelSource: TitleModelSource = .huggingFace
    public var huggingFaceRepo = defaultHuggingFaceRepo
    public var huggingFaceQuant = defaultHuggingFaceQuant
    public var modelFilePath = defaultModelFilePath

    public init() {}

    public static func load(from defaults: UserDefaults = .standard) -> TitleGenerationSettings {
        var settings = TitleGenerationSettings()
        func string(_ key: String) -> String? {
            defaults.string(forKey: key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        if let raw = string(Keys.mode), let mode = TitleGenerationMode(rawValue: raw) { settings.mode = mode }
        if let raw = string(Keys.modelSource), let source = TitleModelSource(rawValue: raw) { settings.modelSource = source }
        if let value = string(Keys.claudeModel) { settings.claudeModel = value }
        if let value = string(Keys.codexModel) { settings.codexModel = value }
        if let value = string(Keys.huggingFaceRepo) { settings.huggingFaceRepo = value }
        if let value = string(Keys.huggingFaceQuant) { settings.huggingFaceQuant = value }
        if let value = string(Keys.modelFilePath) { settings.modelFilePath = value }
        return settings
    }

    /// Where the local model is expected, whether or not it exists yet.
    public var localModelURL: URL {
        switch modelSource {
        case .file:
            URL(fileURLWithPath: (modelFilePath as NSString).expandingTildeInPath)
        case .huggingFace:
            TitleModelDownloader.destination(repo: huggingFaceRepo, quant: huggingFaceQuant)
        }
    }
}
