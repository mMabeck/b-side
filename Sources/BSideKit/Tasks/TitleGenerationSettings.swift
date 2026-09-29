import Foundation

public enum TitleGenerationMode: String, CaseIterable, Identifiable, Sendable {
    case firstWords
    case claude
    case codex
    case localModel
    case openAICompatible

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .firstWords: "First Words of the Prompt"
        case .claude: "Claude CLI"
        case .codex: "Codex CLI"
        case .localModel: "Local Model"
        case .openAICompatible: "OpenAI-Compatible API"
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
        public static let openAIBaseURL = "settings.titleGeneration.openAIBaseURL"
        public static let openAIModel = "settings.titleGeneration.openAIModel"
        public static let promptTemplate = "settings.titleGeneration.promptTemplate"
    }

    public static let promptPlaceholder = "{prompt}"
    /// The wording the local title models were fine-tuned on; changing it can degrade titles.
    public static let defaultPromptTemplate = """
        Write a short English title (2-5 words) for the question below. \
        The question may be in Danish; the title is always in English. Reply with the title only.

        Question: {prompt}
        """

    public static let defaultOpenAIBaseURL = "http://localhost:11434/v1"
    public static let defaultClaudeModel = "haiku"
    public static let defaultHuggingFaceRepo = "Mabeck/qwen3.5-0.8b-kth8-titles"
    public static let defaultHuggingFaceQuant = "Q8_0"
    public static let defaultModelFilePath = "~/Claude/title-gen/models/gguf/qwen3.5-0.8b-title-Q8_0.gguf"

    public var mode: TitleGenerationMode = .localModel
    public var claudeModel = defaultClaudeModel
    public var codexModel = ""
    public var modelSource: TitleModelSource = .huggingFace
    public var huggingFaceRepo = defaultHuggingFaceRepo
    public var huggingFaceQuant = defaultHuggingFaceQuant
    public var modelFilePath = defaultModelFilePath
    public var openAIBaseURL = defaultOpenAIBaseURL
    public var openAIModel = ""
    public var openAIKey = ""
    public var promptTemplate = defaultPromptTemplate

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
        if let value = string(Keys.openAIBaseURL) { settings.openAIBaseURL = value }
        if let value = string(Keys.openAIModel) { settings.openAIModel = value }
        if settings.mode == .openAICompatible { settings.openAIKey = TitleAPIKeychain.read() ?? "" }
        if let value = string(Keys.promptTemplate) { settings.promptTemplate = value }
        return settings
    }

    public var localModelURL: URL {
        switch modelSource {
        case .file:
            URL(fileURLWithPath: (modelFilePath as NSString).expandingTildeInPath)
        case .huggingFace:
            TitleModelDownloader.destination(repo: huggingFaceRepo, quant: huggingFaceQuant)
        }
    }
}
