import Foundation

/// Resolves the `code` CLI and opens a two-file diff (`code --diff base current`)
/// for the Changes overlay's "Open Diff in VS Code" button. Content, not a patch:
/// `code --diff` compares two real files, so the base side is written to a temp
/// file at the diff's base revision and the current side is the worktree file.
public struct VSCodeDiffLauncher {
    public typealias EnvironmentProvider = () -> [String: String]
    public typealias FileExistsCheck = (String) -> Bool

    static let fallbackPaths = [
        "/usr/local/bin/code",
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    ]

    private let environment: EnvironmentProvider
    private let fileExists: FileExistsCheck

    public init(
        environment: @escaping EnvironmentProvider = { ProcessInfo.processInfo.environment },
        fileExists: @escaping FileExistsCheck = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.fileExists = fileExists
    }

    /// Searches `PATH` directories in order, then the known fallback install locations.
    public func resolveCodePath() -> String? {
        let pathVariable = environment()["PATH"] ?? ""
        for directory in pathVariable.split(separator: ":") {
            let candidate = "\(directory)/code"
            if fileExists(candidate) { return candidate }
        }
        return Self.fallbackPaths.first(where: fileExists)
    }

    /// Writes `baseContent`/`currentContent` (`nil` for an added/deleted side) to
    /// sibling temp directories under the same `fileName`, so both sides keep the
    /// original extension for VS Code's own language detection, then runs `code --diff`.
    public func openDiff(fileName: String, baseContent: Data?, currentContent: Data?, codePath: String) throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-vscode-diff-\(UUID().uuidString)", isDirectory: true)
        let baseDir = tempRoot.appendingPathComponent("base", isDirectory: true)
        let currentDir = tempRoot.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)

        let baseURL = baseDir.appendingPathComponent(fileName)
        let currentURL = currentDir.appendingPathComponent(fileName)
        try (baseContent ?? Data()).write(to: baseURL)
        try (currentContent ?? Data()).write(to: currentURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = ["--diff", baseURL.path, currentURL.path]
        try process.run()
    }
}
