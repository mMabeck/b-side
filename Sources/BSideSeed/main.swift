import BSideKit
import Foundation
import GRDB

// Seeds sample projects and tasks into a side-by-side copy's data dir, e.g. `BSideSeed "B-Side Test"`.
let appName = CommandLine.arguments.dropFirst().first ?? ""
guard !appName.isEmpty, appName != AppDatabase.defaultAppSupportName else {
    FileHandle.standardError.write(Data("usage: BSideSeed <app support name, not \(AppDatabase.defaultAppSupportName)>\n".utf8))
    exit(2)
}

let database = try AppDatabase.openStandard(appName: appName)
if try await database.dbQueue.read({ try Project.fetchCount($0) }) > 0 {
    print("\(appName) already has projects; not seeding")
    exit(0)
}

let samplesURL = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    .appendingPathComponent(appName, isDirectory: true)
    .appendingPathComponent("Samples", isDirectory: true)

@discardableResult
func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=B-Side Sample", "-c", "user.email=sample@b-side.invalid"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BSideSeed", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed in \(directory.path)",
        ])
    }
    return String(decoding: data, as: UTF8.self)
}

func write(_ files: [String: String], in directory: URL) throws {
    for (path, contents) in files {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

func commit(_ files: [String: String], message: String, in directory: URL) throws {
    try write(files, in: directory)
    try git(["add", "-A"], in: directory)
    try git(["commit", "-q", "-m", message], in: directory)
}

func makeRepo(named name: String, commits: [(message: String, files: [String: String])]) throws -> URL {
    let url = samplesURL.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], in: url)
    for entry in commits {
        try commit(entry.files, message: entry.message, in: url)
    }
    return url
}

let webURL = try makeRepo(named: "sample-web", commits: [
    ("Initial commit", [
        "README.md": "# Sample Web\n\nA tiny todo app used to try out B-Side.\n",
        "index.html": """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Todos</title>
          <link rel="stylesheet" href="style.css">
        </head>
        <body>
          <h1>Todos</h1>
          <ul id="todos"></ul>
          <script src="app.js"></script>
        </body>
        </html>

        """,
        "style.css": "body {\n  font-family: system-ui, sans-serif;\n  margin: 2rem;\n}\n",
    ]),
    ("Add header styles", [
        "style.css": "body {\n  font-family: system-ui, sans-serif;\n  margin: 2rem;\n}\n\nh1 {\n  font-size: 1.5rem;\n  color: #333;\n}\n",
    ]),
    ("Add todo list logic", [
        "app.js": """
        const todos = ["Buy milk", "Write report"];

        function render() {
          const list = document.getElementById("todos");
          list.innerHTML = todos.map((todo) => `<li>${todo}</li>`).join("");
        }

        render();

        """,
    ]),
])

let cliURL = try makeRepo(named: "sample-cli", commits: [
    ("Initial commit", [
        "README.md": "# Sample CLI\n\nPrints a greeting.\n",
        "greet.py": """
        import sys


        def main() -> None:
            name = sys.argv[1] if len(sys.argv) > 1 else "world"
            print(f"Hello, {name}!")


        if __name__ == "__main__":
            main()

        """,
    ]),
    ("Add usage section", [
        "README.md": "# Sample CLI\n\nPrints a greeting.\n\n## Usage\n\n```sh\npython greet.py Ada\n```\n",
    ]),
])

let store = ProjectsStore(database: database)
try await store.addProject(at: webURL)
try await store.addProject(at: cliURL)
let projects = try await database.dbQueue.read { try Project.order(Project.Columns.sortOrder).fetchAll($0) }
let web = projects[0]
let cli = projects[1]

let darkMode = try await store.createTask(project: web, name: "Add dark mode toggle", useWorktree: true)
let darkModeURL = URL(fileURLWithPath: darkMode.worktreePath)
try write([
    "style.css": """
    body {
      font-family: system-ui, sans-serif;
      margin: 2rem;
    }

    h1 {
      font-size: 1.5rem;
      color: #333;
    }

    body.dark {
      background: #1e1e1e;
      color: #eee;
    }

    body.dark h1 {
      color: #fff;
    }

    """,
    "theme.js": """
    export function toggleTheme() {
      document.body.classList.toggle("dark");
      localStorage.setItem("theme", document.body.classList.contains("dark") ? "dark" : "light");
    }

    """,
], in: darkModeURL)

let persistence = try await store.createTask(project: web, name: "Persist todos in localStorage", useWorktree: true)
let persistenceURL = URL(fileURLWithPath: persistence.worktreePath)
try commit([
    "app.js": """
    const todos = JSON.parse(localStorage.getItem("todos") ?? "[]");

    function save() {
      localStorage.setItem("todos", JSON.stringify(todos));
    }

    function render() {
      const list = document.getElementById("todos");
      list.innerHTML = todos.map((todo) => `<li>${todo}</li>`).join("");
    }

    render();

    """,
], message: "Load and save todos from localStorage", in: persistenceURL)
try write(["README.md": "# Sample Web\n\nA tiny todo app used to try out B-Side.\nTodos are kept in `localStorage`.\n"], in: persistenceURL)
try git(["add", "README.md"], in: persistenceURL)

try await store.createTask(project: cli, name: "Add --json output flag", useWorktree: true)

print("Seeded \(appName): 2 projects, 3 tasks under \(samplesURL.path)")
