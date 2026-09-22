# Dash Native

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
open "dist/Dash Native.app"
```

Run it from the app bundle rather than `swift run`: the SwiftUI `Settings` scene
and user notifications need a real bundle identifier.
