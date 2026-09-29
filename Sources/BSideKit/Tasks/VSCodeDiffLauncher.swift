import Foundation

/// Opens `code --diff` on two temp files, since it compares real files, not patches.
public struct VSCodeDiffLauncher {
    public typealias EnvironmentProvider = () -> [String: String]
    public typealias FileExistsCheck = (String) -> Bool

    static var fallbackPaths: [String] {
        [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code").path,
        ]
    }

    /// Committed mode's current side must come from HEAD, or uncommitted edits leak in and HEAD-only files show empty.
    public enum CurrentSideSource: Equatable, Sendable {
        case none
        case worktreeFile
        case gitRef(String)
    }

    public static func currentSideSource(mode: ChangesOverlayStore.Mode, kind: GitCLI.FileChange.Kind) -> CurrentSideSource {
        guard kind != .deleted else { return .none }
        switch mode {
        case .committed:
            return .gitRef("HEAD")
        case .all, .uncommitted:
            return .worktreeFile
        }
    }

    private let environment: EnvironmentProvider
    private let fileExists: FileExistsCheck

    public init(
        environment: @escaping EnvironmentProvider = { ProcessInfo.processInfo.environment },
        fileExists: @escaping FileExistsCheck = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.fileExists = fileExists
    }

    public func resolveCodePath() -> String? {
        let pathVariable = environment()["PATH"] ?? ""
        for directory in pathVariable.split(separator: ":") {
            let candidate = "\(directory)/code"
            if fileExists(candidate) { return candidate }
        }
        return Self.fallbackPaths.first(where: fileExists)
    }

    /// Both sides share `fileName` in sibling temp dirs so VS Code detects the language.
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
