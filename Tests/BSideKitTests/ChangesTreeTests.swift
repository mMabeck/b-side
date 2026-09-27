import Testing

@testable import BSideKit

@Suite struct ChangesTreeTests {
    private func file(
        _ path: String,
        origPath: String? = nil,
        kind: GitCLI.FileChange.Kind = .modified,
        added: Int? = nil,
        removed: Int? = nil,
        isBinary: Bool = false
    ) -> ChangesTreeFile {
        ChangesTreeFile(path: path, origPath: origPath, kind: kind, linesAdded: added, linesRemoved: removed, isBinary: isBinary)
    }

    @Test func emptyInputProducesNoNodes() {
        #expect(ChangesTreeBuilder.build([ChangesTreeFile]()).isEmpty)
    }

    @Test func rootLevelFilesAreLeaves() {
        let tree = ChangesTreeBuilder.build([file("README.md"), file("Package.swift")])
        #expect(tree.count == 2)
        for node in tree {
            #expect(node.children == nil)
        }
        #expect(tree.map(\.displayName) == ["Package.swift", "README.md"])
    }

    @Test func foldersSortBeforeFilesAtTheSameLevel() {
        let tree = ChangesTreeBuilder.build([
            file("z.txt"),
            file("a/b.txt"),
        ])
        #expect(tree.count == 2)
        guard case .folder = tree[0] else {
            Issue.record("expected the folder to sort first")
            return
        }
        guard case .file = tree[1] else {
            Issue.record("expected the file to sort last")
            return
        }
    }

    @Test func siblingsSortAlphabeticallyWithNumericAwareness() {
        let tree = ChangesTreeBuilder.build([
            file("file10.txt"),
            file("file2.txt"),
            file("file1.txt"),
        ])
        #expect(tree.map(\.displayName) == ["file1.txt", "file2.txt", "file10.txt"])
    }

    @Test func singleChildFolderChainsCompress() {
        let tree = ChangesTreeBuilder.build([file("a/b/c/File.swift")])
        #expect(tree.count == 1)
        guard case .folder(let folder) = tree[0] else {
            Issue.record("expected a compressed folder node")
            return
        }
        #expect(folder.displayName == "a/b/c")
        #expect(folder.id == "a/b/c")
        #expect(folder.children.count == 1)
        #expect(folder.children.first?.displayName == "File.swift")
    }

    @Test func branchingFolderStopsCompression() {
        let tree = ChangesTreeBuilder.build([
            file("a/b/One.swift"),
            file("a/b/Two.swift"),
            file("a/Other.swift"),
        ])
        // "a" has two entries directly under it (the "b" folder and
        // "Other.swift"), so it cannot compress into "a/b" — but "b" itself
        // has only files (no further single-child folder chain) so it stays
        // a folder named "b" nested under "a".
        #expect(tree.count == 1)
        guard case .folder(let a) = tree[0] else {
            Issue.record("expected a top-level folder")
            return
        }
        #expect(a.displayName == "a")
        #expect(a.children.count == 2)
        let names = Set(a.children.map(\.displayName))
        #expect(names == ["b", "Other.swift"])
    }

    @Test func aFolderWithBothAFileAndASubfolderDoesNotCompress() {
        let tree = ChangesTreeBuilder.build([
            file("a/b/File.swift"),
            file("a/Direct.swift"),
        ])
        #expect(tree.count == 1)
        guard case .folder(let a) = tree[0] else {
            Issue.record("expected a top-level folder")
            return
        }
        #expect(a.displayName == "a")
        #expect(a.children.count == 2)
    }

    @Test func fileCountsAggregateUpTheCompressedChain() {
        let tree = ChangesTreeBuilder.build([
            file("a/b/One.swift", added: 3, removed: 1),
            file("a/b/Two.swift", added: 5, removed: 0),
        ])
        guard case .folder(let folder) = tree.first else {
            Issue.record("expected a compressed folder node")
            return
        }
        #expect(folder.displayName == "a/b")
        #expect(folder.linesAdded == 8)
        #expect(folder.linesRemoved == 1)
    }

    @Test func renamedFilesAreLocatedByTheirNewPath() {
        let tree = ChangesTreeBuilder.build([
            file("new/Name.swift", origPath: "old/Name.swift", kind: .renamed),
        ])
        #expect(tree.count == 1)
        guard case .folder(let folder) = tree[0] else {
            Issue.record("expected a folder for the new path")
            return
        }
        #expect(folder.displayName == "new")
        guard case .file(let renamedFile) = folder.children.first else {
            Issue.record("expected the renamed file under its new path")
            return
        }
        #expect(renamedFile.path == "new/Name.swift")
        #expect(renamedFile.origPath == "old/Name.swift")
    }

    private func row(_ path: String, origin: SourceControlStore.Row.Origin, added: Int? = nil, removed: Int? = nil) -> SourceControlStore.Row {
        if origin == .branch {
            return SourceControlStore.Row(
                branchChange: GitCLI.BranchFileChange(path: path, kind: .modified, linesAdded: added, linesRemoved: removed, isBinary: false)
            )
        }
        return SourceControlStore.Row(
            fileChange: GitCLI.FileChange(
                path: path,
                kind: .modified,
                area: origin == .staged ? .staged : .unstaged,
                linesAdded: added,
                linesRemoved: removed
            ),
            origin: origin
        )
    }

    @Test(arguments: [
        SourceControlStore.Row.Origin.staged,
        SourceControlStore.Row.Origin.unstaged,
        SourceControlStore.Row.Origin.branch,
    ])
    func buildingFromRowsPreservesRowIdentityAndAggregatesCounts(origin: SourceControlStore.Row.Origin) {
        let tree = ChangesTreeBuilder.build([
            row("a/b/One.swift", origin: origin, added: 3, removed: 1),
            row("a/b/Two.swift", origin: origin, added: 5, removed: 0),
        ])
        guard case .folder(let folder) = tree.first else {
            Issue.record("expected a compressed folder node")
            return
        }
        #expect(folder.displayName == "a/b")
        #expect(folder.linesAdded == 8)
        #expect(folder.linesRemoved == 1)
        guard case .file(let firstRow) = folder.children.first else {
            Issue.record("expected a file leaf carrying the original row")
            return
        }
        #expect(firstRow.origin == origin)
    }
}
