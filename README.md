<p align="center"><img src="docs/icon.png" width="128" alt="B-Side app icon"></p>

# B-Side

A native macOS app for running several [Pi](https://github.com/earendil-works/pi)
coding agents side by side without them stepping on each other.

Every task gets its own git branch and worktree, and its own Pi session in a
real terminal (libghostty). Switch between tasks from the sidebar and each one
picks up where you left it: the terminal keeps running in the background, and
reopening the app resumes the same Pi session instead of starting over.

![B-Side with sample projects and a fresh Pi session](docs/screenshots/pi.png)

## What it does

- **Projects and tasks.** Add a git repository as a project; each new task
  branches from it into a separate worktree, so parallel agents never share a
  working copy.
- **Pi in a real terminal.** Sessions run in embedded Ghostty terminals and
  follow your Ghostty theme and font, or a theme you pick in Settings.
- **Subagents at a glance.** When a session starts subagents, they appear as
  live cards above its terminal, showing what each one is doing; click a card to
  watch that agent's own terminal.
- **Source control built in.** A sidebar shows the task's changes, with
  staging, commit and push, and a full diff view.
- **Notifications.** A sound and a macOS notification when Pi finishes or needs
  an answer, so you can leave it running in the background.

![A task with two subagents running](docs/screenshots/subagents.png)

## Requirements

macOS 26 on Apple Silicon only — the libghostty XCFramework is arm64.

Building requires Xcode (not just the Command Line Tools) — the Command Line
Tools toolchain ships without the Swift Testing frameworks, so `swift test`
cannot link against it. Check the right one is selected with `xcode-select -p`;
it should print a path inside `Xcode.app`.

## Build

```sh
swift build
```

## Test

```sh
swift test
```

Filter to one suite with `swift test --filter GitCLITests`.

## Run

```sh
./scripts/bundle.sh
open "dist/B-Side.app"
```

Run it from the app bundle rather than `swift run`: the SwiftUI `Settings` scene
and user notifications need a real bundle identifier.

## Upgrading from Dash Native

The app renamed itself, and so did the two places it keeps state. Both migrate
themselves once, on first use, by moving the old directory into place:

- `~/Library/Application Support/DashNative` → `.../B-Side`
- a project's `.dash/` → `.bside/`

The second happens inside your repository's working tree, so the first time
B-Side opens a project you already used with Dash Native, expect `.dash/` →
`.bside/` to show up in `git status`. If a move fails, the app keeps reading the
old location and retries next launch rather than starting empty.
