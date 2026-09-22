# Dash Native

A from-scratch, macOS-only, Swift rewrite of Dash Pi. Native AppKit/SwiftUI,
libghostty for terminals, git worktrees as the organising principle.

The authoritative spec is [`docs/native-rewrite.md`](docs/native-rewrite.md).

Apple Silicon only — the libghostty XCFramework is arm64.

## Build

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build
```

`DEVELOPER_DIR` pins the CommandLineTools toolchain. `scripts/test.sh` and
`scripts/bundle.sh` set it themselves, so it is only needed for a bare
`swift build`.

## Test

```sh
./scripts/test.sh
```

Always use this wrapper — a bare `swift test` builds but fails to load. The
CommandLineTools toolchain keeps `Testing.framework` and `lib_TestingInterop.dylib`
off the default search path, and `DYLD_*` overrides do not survive SIP when SwiftPM
spawns `swiftpm-testing-helper`, so the wrapper bakes both paths in as rpaths at
link time.

Arguments pass through, e.g. `./scripts/test.sh --filter GitCLITests`.

## Run

```sh
./scripts/bundle.sh
open "dist/Dash Native.app"
```

Run it from the app bundle rather than `swift run`: the SwiftUI `Settings` scene
and user notifications need a real bundle identifier.
