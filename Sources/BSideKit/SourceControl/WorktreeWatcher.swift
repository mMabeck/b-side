import CoreServices
import Foundation

/// FSEvents-backed watcher behind the Source Control sidebar's live refresh
/// (native-rewrite.md §7 "Live refresh"). Watches two things:
///
/// - The worktree root, for edits to tracked/untracked files — ignoring
///   anything under its own `.git` (a file, for a linked worktree, but
///   ignored by path prefix either way; the real git directory is watched
///   separately below).
/// - The real git directory (resolved through the `.git` pointer file for a
///   linked worktree), restricted to `index`, `HEAD`, and `refs/**` — the
///   only paths there that change what `git status`/`branchChanges` report.
///
/// Both streams coalesce bursts of events into a single refresh roughly
/// every 300ms (`debounceInterval`), since agents write files in bursts and a
/// refresh per write is unusable.
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

        // For a linked worktree, `refs/heads`, `refs/remotes`, and
        // `packed-refs` live in the *common* git dir shared by every worktree
        // — not in `gitDir` above, which is this worktree's private
        // `worktrees/<name>/` directory (HEAD, index, per-worktree refs).
        // Without this, a commit or fetch made from a terminal in this
        // worktree never updates `refs/heads/<branch>` where `gitDirStream`
        // is looking, and the sidebar never refreshes.
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

    /// Only `index`, `HEAD`, and anything under `refs/` change what the
    /// sidebar shows; everything else in a git directory (`COMMIT_EDITMSG`,
    /// lock files, `logs/`, hooks output, ...) is noise.
    private static func isRelevantGitDirPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "index" || name == "HEAD" { return true }
        return path.contains("/refs/") || path.hasSuffix("/refs")
    }

    /// In the *common* git dir (shared across worktrees), only branch and
    /// remote-tracking refs matter to the sidebar — not e.g. `refs/stash` or
    /// `refs/bisect`, and not the many non-ref files there (`config`,
    /// `hooks/`, `objects/`, ...).
    private static func isRelevantCommonGitDirPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "packed-refs" { return true }
        return path.contains("/refs/heads/") || path.hasSuffix("/refs/heads")
            || path.contains("/refs/remotes/") || path.hasSuffix("/refs/remotes")
    }

    /// Resolves the common git dir shared by every worktree of a repository,
    /// given `gitDir` (a worktree's own, possibly private, git directory) —
    /// the analogue of `git rev-parse --git-common-dir`, without shelling out.
    /// A linked worktree's git dir has a `commondir` file with a path (usually
    /// `../..`) relative to itself pointing at the shared dir; a non-linked
    /// git dir (the main checkout) has none and *is* the common dir.
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

    /// Resolves the real git directory for `worktreeURL`. For a linked
    /// worktree, `.git` is a file containing `gitdir: <path>`, not a
    /// directory — this reads and resolves that pointer (relative paths are
    /// relative to the worktree root) so the watcher targets the actual
    /// `refs`/`index`/`HEAD` location under the main repository's
    /// `worktrees/<name>/`, not the tiny pointer file itself.
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

    /// Thin wrapper over `FSEventStreamCreate`, dispatched on the main queue
    /// so `callback` always runs where `MainActor.assumeIsolated` at the call
    /// sites above is safe. `callback` receives the raw list of changed paths
    /// for one coalesced batch of events; flags aren't needed since both
    /// callers only care about *which* paths changed.
    private static func makeStream(
        paths: [String],
        latency: CFTimeInterval,
        callback: @escaping ([String]) -> Void
    ) -> FSEventStreamRef? {
        final class CallbackBox {
            let callback: ([String]) -> Void
            init(_ callback: @escaping ([String]) -> Void) { self.callback = callback }
        }

        // `info` is handed to `FSEventStreamCreate` unretained: the `retain`
        // callback below is what gives the stream its own +1 when the
        // context is copied. Using `passRetained` here as well double-counted
        // the retain (one from here, one from the framework's own `retain`
        // call), so `release` — called once, on `FSEventStreamInvalidate`/
        // deinit — only ever brought the count back to 1, leaking `box` (and
        // its captured `callback`, and whatever it in turn captures) for the
        // life of the process.
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
