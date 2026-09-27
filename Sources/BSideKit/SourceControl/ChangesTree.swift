import Foundation

/// Independent of `GitCLI.BranchFileChange`/`FileChange` so the builder is
/// directly unit testable. `path` is always the current path (the new name
/// for a rename); `origPath` is kept only for display, never for tree placement.
public struct ChangesTreeFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let origPath: String?
    public let kind: GitCLI.FileChange.Kind
    public let linesAdded: Int?
    public let linesRemoved: Int?
    public let isBinary: Bool

    public var id: String { path }

    public init(
        path: String,
        origPath: String? = nil,
        kind: GitCLI.FileChange.Kind,
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        isBinary: Bool = false
    ) {
        self.path = path
        self.origPath = origPath
        self.kind = kind
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isBinary = isBinary
    }
}

/// A chain of folders each with exactly one child and no files of their own
/// is compressed into a single node (`a/b/c`, not three nested rows) — VS Code's "compact folders".
public enum ChangesTreeNode: Sendable, Equatable, Identifiable {
    case file(ChangesTreeFile)
    case folder(Folder)

    public struct Folder: Sendable, Equatable {
        /// Full path post-compression, e.g. `"Sources/BSideKit/Git"` — unique, doubles as the node's `id`.
        public let id: String
        /// The compressed chain relative to its parent row, e.g. `"BSideKit/Git"`.
        public let displayName: String
        public let children: [ChangesTreeNode]
        public let linesAdded: Int
        public let linesRemoved: Int
    }

    public var id: String {
        switch self {
        case .file(let file): return file.id
        case .folder(let folder): return folder.id
        }
    }

    public var displayName: String {
        switch self {
        case .file(let file): return (file.path as NSString).lastPathComponent
        case .folder(let folder): return folder.displayName
        }
    }

    /// The shape `OutlineGroup(_:children:)` expects.
    public var children: [ChangesTreeNode]? {
        if case .folder(let folder) = self { return folder.children }
        return nil
    }
}

/// Pure and git-agnostic, so it's directly unit testable without a repository.
public enum ChangesTreeBuilder {
    /// Folders sorted before files, each group alphabetical (`localizedStandardCompare`, so `file2` sorts before `file10`).
    public static func build(_ files: [ChangesTreeFile]) -> [ChangesTreeNode] {
        guard !files.isEmpty else { return [] }
        let root = MutableNode(path: "")
        for file in files {
            var components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            let fileName = components.removeLast()
            var current = root
            var pathSoFar = ""
            for component in components {
                pathSoFar = pathSoFar.isEmpty ? component : "\(pathSoFar)/\(component)"
                if let existing = current.folderChildren[component] {
                    current = existing
                } else {
                    let node = MutableNode(path: pathSoFar)
                    current.folderChildren[component] = node
                    current = node
                }
            }
            current.files[fileName] = file
        }
        return root.compressedChildren()
    }

    /// Mutable representation used only while building; converted to `ChangesTreeNode` once assembled.
    private final class MutableNode {
        /// Uncompressed; becomes a folder's `id` once it stops being collapsed into its parent's row.
        let path: String
        var folderChildren: [String: MutableNode] = [:]
        var files: [String: ChangesTreeFile] = [:]

        init(path: String) { self.path = path }

        func compressedChildren() -> [ChangesTreeNode] {
            let folders = folderChildren
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child in child.compressed(name: name) }
            let fileNodes = files
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { ChangesTreeNode.file($0.value) }
            return folders + fileNodes
        }

        /// Recurses until a folder with more than one entry (or a file of
        /// its own) is reached; `name` accumulates the label across the chain.
        func compressed(name: String) -> ChangesTreeNode {
            if files.isEmpty, folderChildren.count == 1, let onlyChild = folderChildren.first {
                return onlyChild.value.compressed(name: "\(name)/\(onlyChild.key)")
            }
            let children = compressedChildren()
            let (added, removed) = MutableNode.aggregate(children)
            return .folder(.init(id: path, displayName: name, children: children, linesAdded: added, linesRemoved: removed))
        }

        private static func aggregate(_ nodes: [ChangesTreeNode]) -> (added: Int, removed: Int) {
            var added = 0
            var removed = 0
            for node in nodes {
                switch node {
                case .file(let file):
                    added += file.linesAdded ?? 0
                    removed += file.linesRemoved ?? 0
                case .folder(let folder):
                    added += folder.linesAdded
                    removed += folder.linesRemoved
                }
            }
            return (added, removed)
        }
    }
}
