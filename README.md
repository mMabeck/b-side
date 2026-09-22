# Dash Native

A from-scratch, macOS-only, Swift rewrite of Dash Pi. Native AppKit/SwiftUI,
libghostty for terminals, git worktrees as the organising principle.

The authoritative spec is [`docs/native-rewrite.md`](docs/native-rewrite.md).

## Build

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build
```

Apple Silicon only — the libghostty XCFramework is arm64.
