import Foundation

/// In-app rather than llama.cpp's `-hf`, which rejects some valid long OAuth-style HF tokens
/// and so can't reach private repos.
@MainActor
public final class TitleModelDownloader: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case downloading(fraction: Double?)
        case failed(String)
    }

    public static let shared = TitleModelDownloader()

    @Published public private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    public nonisolated static func destination(repo: String, quant: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let repoDirectory = repo.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "--")
        return appSupport
            .appendingPathComponent("B-Side/TitleModels", isDirectory: true)
            .appendingPathComponent(repoDirectory, isDirectory: true)
            .appendingPathComponent("\(quant.trimmingCharacters(in: .whitespaces)).gguf")
    }

    public func download(repo: String, quant: String) {
        guard task == nil else { return }
        state = .downloading(fraction: nil)
        task = Task {
            do {
                try await Self.fetch(repo: repo, quant: quant) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(fraction: fraction) }
                    }
                }
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    private nonisolated static func fetch(
        repo: String,
        quant: String,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        let token = huggingFaceToken()

        let fileName = try await ggufFileName(repo: repo, quant: quant, token: token)
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)") else {
            throw DownloadError("Invalid repository name.")
        }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let progress = ProgressDelegate(onProgress: onProgress)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request, delegate: progress)
        try check(response)

        let destination = destination(repo: repo, quant: quant)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private nonisolated static func ggufFileName(repo: String, quant: String, token: String?) async throws -> String {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw DownloadError("Invalid repository name.")
        }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)

        struct ModelInfo: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let siblings: [Sibling]
        }
        let files = try JSONDecoder().decode(ModelInfo.self, from: data).siblings.map(\.rfilename)
        let quant = quant.trimmingCharacters(in: .whitespaces).lowercased()
        guard
            let match = files.first(where: {
                let name = $0.lowercased()
                return name.hasSuffix(".gguf") && name.contains(quant)
            })
        else {
            throw DownloadError("No .gguf file matching \"\(quant)\" in \(repo).")
        }
        return match
    }

    private nonisolated static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
        switch status {
        case 401, 403: throw DownloadError("Access denied (\(status)). Private repos need `hf auth login`.")
        case 404: throw DownloadError("Repository or file not found.")
        default: throw DownloadError("Hugging Face returned HTTP \(status).")
        }
    }

    nonisolated static func huggingFaceToken() -> String? {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty { return token }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/token")
        let token = (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

private struct DownloadError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double?) -> Void

    init(onProgress: @escaping @Sendable (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
