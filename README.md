# B-Side

A from-scratch, macOS-only, Swift rewrite of Dash Pi. Native AppKit/SwiftUI,
libghostty for terminals, git worktrees as the organising principle.

The authoritative spec is [`docs/native-rewrite.md`](docs/native-rewrite.md).

Apple Silicon only — the libghostty XCFramework is arm64.

Requires Xcode (not just the Command Line Tools) — the Command Line Tools
toolchain ships without the Swift Testing frameworks, so `swift test` cannot
link against it. Check the right one is selected with `xcode-select -p`; it
should print a path inside `Xcode.app`.

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
