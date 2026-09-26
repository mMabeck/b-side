import Foundation

/// One changed file as the Changes overlay's tree builder consumes it —
/// independent of `GitCLI.BranchFileChange`/`FileChange` so the builder
/// itself needs no git-specific area/origin concepts and is directly unit
/// testable. `path` is always the current path — for a rename, that's the
/// new name; `origPath` is kept only for display, never used to place the
/// node in the tree.
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

/// One node in the Changes overlay's file tree: either a changed file, or a
/// folder aggregating the files beneath it. A chain of folders that each
/// have exactly one child and no files of their own is compressed into a
/// single node (`a/b/c` rather than three nested single-child rows) — VS
/// Code's "compact folders" behaviour.
public enum ChangesTreeNode: Sendable, Equatable, Identifiable {
    case file(ChangesTreeFile)
    case folder(Folder)

    public struct Folder: Sendable, Equatable {
        /// Full path from the tree's root to this folder (post-compression),
        /// e.g. `"Sources/BSideKit/Git"` — unique, so it doubles as the
        /// node's `id`.
        public let id: String
        /// The label to render for this row: the compressed chain relative
        /// to its parent row, e.g. `"BSideKit/Git"` when `Sources` is its
        /// own row above it.
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

    /// `nil` for a file (a leaf), `[ChangesTreeNode]` for a folder — the
    /// shape `OutlineGroup(_:children:)` expects.
    public var children: [ChangesTreeNode]? {
        if case .folder(let folder) = self { return folder.children }
        return nil
    }
}

/// Builds a compressed folder tree from a flat list of changed files. Pure
/// and git-agnostic beyond `ChangesTreeFile`'s own `GitCLI.FileChange.Kind`,
/// so it's directly unit testable without a repository.
public enum ChangesTreeBuilder {
    /// - Returns: Root-level nodes, folders sorted before files and each
    ///   group sorted alphabetically (`localizedStandardCompare`, so e.g.
    ///   `file2` sorts before `file10`).
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

    /// Intermediate, mutable representation used only while building the
    /// tree; converted to the immutable `ChangesTreeNode` once assembled.
    private final class MutableNode {
        /// This node's own full path from the tree root, uncompressed —
        /// becomes a folder's `id` once it stops being collapsed into its
        /// parent's row.
        let path: String
        var folderChildren: [String: MutableNode] = [:]
        var files: [String: ChangesTreeFile] = [:]

        init(path: String) { self.path = path }

        /// This node's children as immutable, sorted `ChangesTreeNode`s.
        func compressedChildren() -> [ChangesTreeNode] {
            let folders = folderChildren
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child in child.compressed(name: name) }
            let fileNodes = files
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { ChangesTreeNode.file($0.value) }
            return folders + fileNodes
        }

        /// Collapses a chain of single-child, file-less folders into one
        /// node labelled `"a/b/c"`, recursing until a folder with more than
        /// one entry (or a file of its own) is reached. `name` accumulates
        /// the display label across the chain; `path` (this node's own,
        /// uncompressed) is always the correct `id` for wherever the chain
        /// bottoms out.
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
