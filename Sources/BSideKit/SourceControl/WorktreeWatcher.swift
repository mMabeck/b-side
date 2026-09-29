import CoreServices
import Foundation

/// Watches the worktree root (ignoring its `.git`) and the real git dir restricted to `index`/`HEAD`/`refs/**`, coalescing bursts (`debounceInterval`).
@MainActor
final class WorktreeWatcher {
    private let worktreeURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    nonisolated(unsafe) private var workTreeStream: FSEventStreamRef?
    nonisolated(unsafe) private var gitDirStream: FSEventStreamRef?
    nonisolated(unsafe) private var commonGitDirStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init(worktreeURL: URL, debounceInterval: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.worktreeURL = worktreeURL
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        if let workTreeStream {
            FSEventStreamStop(workTreeStream)
            FSEventStreamInvalidate(workTreeStream)
            FSEventStreamRelease(workTreeStream)
        }
        if let gitDirStream {
            FSEventStreamStop(gitDirStream)
            FSEventStreamInvalidate(gitDirStream)
            FSEventStreamRelease(gitDirStream)
        }
        if let commonGitDirStream {
            FSEventStreamStop(commonGitDirStream)
            FSEventStreamInvalidate(commonGitDirStream)
            FSEventStreamRelease(commonGitDirStream)
        }
    }

    func start() {
        stop()

        let gitFilePrefix = worktreeURL.appendingPathComponent(".git").standardizedFileURL.path
        workTreeStream = Self.makeStream(paths: [worktreeURL.standardizedFileURL.path], latency: 0.2) { [weak self] paths in
            MainActor.assumeIsolated {
                let relevant = paths.contains { path in
                    path != gitFilePrefix && !path.hasPrefix(gitFilePrefix + "/")
                }
                guard relevant else { return }
                self?.scheduleRefresh()
            }
        }

        let gitDir = Self.resolveGitDir(forWorktree: worktreeURL)
        if let gitDir {
            gitDirStream = Self.makeStream(paths: [gitDir.standardizedFileURL.path], latency: 0.2) { [weak self] paths in
                MainActor.assumeIsolated {
                    let relevant = paths.contains { Self.isRelevantGitDirPath($0) }
                    guard relevant else { return }
                    self?.scheduleRefresh()
                }
            }
        }

        // A linked worktree's shared refs live in the *common* git dir, not `gitDir`; without this the sidebar never sees a commit/fetch made elsewhere.
        if let gitDir, let commonGitDir = Self.resolveCommonGitDir(forGitDir: gitDir), commonGitDir != gitDir {
            commonGitDirStream = Self.makeStream(paths: [commonGitDir.standardizedFileURL.path], latency: 0.2) { [weak self] paths in
                MainActor.assumeIsolated {
                    let relevant = paths.contains { Self.isRelevantCommonGitDirPath($0) }
                    guard relevant else { return }
                    self?.scheduleRefresh()
                }
            }
        }
    }

    func stop() {
        if let workTreeStream {
            FSEventStreamStop(workTreeStream)
            FSEventStreamInvalidate(workTreeStream)
            FSEventStreamRelease(workTreeStream)
            self.workTreeStream = nil
        }
        if let gitDirStream {
            FSEventStreamStop(gitDirStream)
            FSEventStreamInvalidate(gitDirStream)
            FSEventStreamRelease(gitDirStream)
            self.gitDirStream = nil
        }
        if let commonGitDirStream {
            FSEventStreamStop(commonGitDirStream)
            FSEventStreamInvalidate(commonGitDirStream)
            FSEventStreamRelease(commonGitDirStream)
            self.commonGitDirStream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private static func isRelevantGitDirPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "index" || name == "HEAD" { return true }
        return path.contains("/refs/") || path.hasSuffix("/refs")
    }

    static func isRelevantCommonGitDirPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "packed-refs" { return true }
        return path.contains("/refs/heads/") || path.hasSuffix("/refs/heads")
            || path.contains("/refs/remotes/") || path.hasSuffix("/refs/remotes")
    }

    /// `git rev-parse --git-common-dir` without shelling out: a linked worktree has a `commondir` file; the main checkout is itself the common dir.
    static func resolveCommonGitDir(forGitDir gitDir: URL) -> URL? {
        let commondirFile = gitDir.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commondirFile, encoding: .utf8) else {
            return gitDir
        }
        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDir }
        let resolved = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : gitDir.appendingPathComponent(rawPath)
        return resolved.standardizedFileURL
    }

    /// A linked worktree's `.git` is a file containing `gitdir: <path>`.
    static func resolveGitDir(forWorktree worktreeURL: URL) -> URL? {
        let gitPath = worktreeURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            return gitPath
        }

        guard let contents = try? String(contentsOf: gitPath, encoding: .utf8) else { return nil }
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let resolved = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : worktreeURL.appendingPathComponent(rawPath)
        return resolved.standardizedFileURL
    }

    /// Dispatched on the main queue so `callback` runs where `MainActor.assumeIsolated` above is safe.
    static func makeStream(
        paths: [String],
        latency: CFTimeInterval,
        callback: @escaping ([String]) -> Void
    ) -> FSEventStreamRef? {
        final class CallbackBox {
            let callback: ([String]) -> Void
            init(_ callback: @escaping ([String]) -> Void) { self.callback = callback }
        }

        // `info` is passed unretained: the `retain` callback gives the stream its own +1, so `passRetained` here would leak `box`.
        let box = CallbackBox(callback)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let cCallback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let clientCallBackInfo else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            guard let cfArray = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            box.callback(cfArray)
            _ = numEvents
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        return stream
    }
}
