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

/// A leaf the tree builder can place by `path` and aggregate `+`/`-` counts
/// for. Conformed to by both `ChangesTreeFile` (the Changes overlay) and
/// `SourceControlStore.Row` (the sidebar), so `id` stays whatever the caller
/// already uses to key selection/diffing — a plain path for the former, an
/// origin-prefixed path (`"staged:..."`) for the latter.
public protocol ChangesTreeLeaf: Sendable, Equatable, Identifiable where ID == String {
    var path: String { get }
    var linesAdded: Int? { get }
    var linesRemoved: Int? { get }
}

extension ChangesTreeFile: ChangesTreeLeaf {}
extension SourceControlStore.Row: ChangesTreeLeaf {}

/// A chain of folders each with exactly one child and no files of their own
/// is compressed into a single node (`a/b/c`, not three nested rows) — VS Code's "compact folders".
public enum AnyChangesTreeNode<Leaf: ChangesTreeLeaf>: Sendable, Equatable, Identifiable {
    case file(Leaf)
    case folder(Folder)

    public struct Folder: Sendable, Equatable {
        /// Full path post-compression, e.g. `"Sources/BSideKit/Git"` — unique, doubles as the node's `id`.
        public let id: String
        /// The compressed chain relative to its parent row, e.g. `"BSideKit/Git"`.
        public let displayName: String
        public let children: [AnyChangesTreeNode<Leaf>]
        public let linesAdded: Int
        public let linesRemoved: Int
    }

    public var id: String {
        switch self {
        case .file(let leaf): return leaf.id
        case .folder(let folder): return folder.id
        }
    }

    public var displayName: String {
        switch self {
        case .file(let leaf): return (leaf.path as NSString).lastPathComponent
        case .folder(let folder): return folder.displayName
        }
    }

    /// The shape `OutlineGroup(_:children:)` expects.
    public var children: [AnyChangesTreeNode<Leaf>]? {
        if case .folder(let folder) = self { return folder.children }
        return nil
    }

    /// All file leaves under this node, depth-first — used for folder-level
    /// stage/unstage, which acts on every file the folder contains.
    public var leaves: [Leaf] {
        switch self {
        case .file(let leaf): return [leaf]
        case .folder(let folder): return folder.children.flatMap(\.leaves)
        }
    }
}

/// The Changes overlay's tree, keyed by plain file path.
public typealias ChangesTreeNode = AnyChangesTreeNode<ChangesTreeFile>
/// The Source Control sidebar's tree, keyed by `SourceControlStore.Row.id` so hover actions and click-to-diff need no separate lookup.
public typealias ChangesTreeRowNode = AnyChangesTreeNode<SourceControlStore.Row>

/// Pure and git-agnostic, so it's directly unit testable without a repository.
public enum ChangesTreeBuilder {
    /// Folders sorted before files, each group alphabetical (`localizedStandardCompare`, so `file2` sorts before `file10`).
    public static func build(_ files: [ChangesTreeFile]) -> [ChangesTreeNode] {
        build(leaves: files)
    }

    /// Same tree shape, built directly from sidebar rows so folder/file nodes carry the row's own `id`.
    public static func build(_ rows: [SourceControlStore.Row]) -> [ChangesTreeRowNode] {
        build(leaves: rows)
    }

    private static func build<Leaf: ChangesTreeLeaf>(leaves: [Leaf]) -> [AnyChangesTreeNode<Leaf>] {
        guard !leaves.isEmpty else { return [] }
        let root = MutableNode<Leaf>(path: "")
        for leaf in leaves {
            var components = leaf.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            let fileName = components.removeLast()
            var current = root
            var pathSoFar = ""
            for component in components {
                pathSoFar = pathSoFar.isEmpty ? component : "\(pathSoFar)/\(component)"
                if let existing = current.folderChildren[component] {
                    current = existing
                } else {
                    let node = MutableNode<Leaf>(path: pathSoFar)
                    current.folderChildren[component] = node
                    current = node
                }
            }
            current.files[fileName] = leaf
        }
        return root.compressedChildren()
    }

    /// Mutable representation used only while building; converted to `AnyChangesTreeNode` once assembled.
    private final class MutableNode<Leaf: ChangesTreeLeaf> {
        /// Uncompressed; becomes a folder's `id` once it stops being collapsed into its parent's row.
        let path: String
        var folderChildren: [String: MutableNode<Leaf>] = [:]
        var files: [String: Leaf] = [:]

        init(path: String) { self.path = path }

        func compressedChildren() -> [AnyChangesTreeNode<Leaf>] {
            let folders = folderChildren
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child in child.compressed(name: name) }
            let fileNodes = files
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { AnyChangesTreeNode<Leaf>.file($0.value) }
            return folders + fileNodes
        }

        /// Recurses until a folder with more than one entry (or a file of
        /// its own) is reached; `name` accumulates the label across the chain.
        func compressed(name: String) -> AnyChangesTreeNode<Leaf> {
            if files.isEmpty, folderChildren.count == 1, let onlyChild = folderChildren.first {
                return onlyChild.value.compressed(name: "\(name)/\(onlyChild.key)")
            }
            let children = compressedChildren()
            let (added, removed) = MutableNode.aggregate(children)
            return .folder(.init(id: path, displayName: name, children: children, linesAdded: added, linesRemoved: removed))
        }

        private static func aggregate(_ nodes: [AnyChangesTreeNode<Leaf>]) -> (added: Int, removed: Int) {
            var added = 0
            var removed = 0
            for node in nodes {
                switch node {
                case .file(let leaf):
                    added += leaf.linesAdded ?? 0
                    removed += leaf.linesRemoved ?? 0
                case .folder(let folder):
                    added += folder.linesAdded
                    removed += folder.linesRemoved
                }
            }
            return (added, removed)
        }
    }
}
