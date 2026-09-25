# B-Side

macOS-only Swift rewrite of Dash Pi: a native app that runs Pi agent sessions in
embedded libghostty terminals, one per task, organised around git branches and
worktrees. The authoritative spec is [`docs/native-rewrite.md`](docs/native-rewrite.md);
visual identity is in [`docs/brand.md`](docs/brand.md). Formerly "Dash Native".

## Stack

- Swift 6 (tools 6.0), SwiftPM, macOS 14+, **arm64 only** (the libghostty
  XCFramework is arm64).
- SwiftUI + AppKit; structured concurrency, not Combine.
- GRDB (SQLite) with explicit migrations and foreign-key cascades.
- libghostty via `Lakr233/libghostty-spm`, pinned `exact:` in `Package.swift`.
- Tests use Swift Testing (`@Test`, `#expect`), not XCTest assertions.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/BSide/` | App entry point only (`BSideApp.swift`). |
| `Sources/BSideKit/` | Everything else; the testable library. |
| `BSideKit/Git/` | `GitCLI`, a thin wrapper over the `git` binary. |
| `BSideKit/Persistence/` | `AppDatabase`, `Migrations`. |
| `BSideKit/State/` | `ProjectsStore`: project/task selection. |
| `BSideKit/Tasks/` | Worktree creation, Pi launch/resume, auto-rename, `.bside/config.json`. |
| `BSideKit/Terminal/` | libghostty interop and theming. |
| `BSideKit/Subagents/` | Loopback HTTP/JSONL feed of Pi child events, card strip, pane swap. |
| `scripts/bundle.sh` | Release build + `dist/B-Side.app` assembly. |
| `assets/theme/` | Bundled Ghostty themes (`b-side.conf`, `b-side-paper.conf`). |
| `.bside/config.json` | This repo's own B-Side project config (task defaults). Tracked. |

## Running it

```sh
swift build
./scripts/bundle.sh && open dist/B-Side.app
```

Use the bundle, not `swift run`: the Settings scene and notifications need a
real bundle identifier. A clean release build can take ~10 minutes.

## Testing

```sh
swift test
swift test --filter GitCLITests
```

- Requires full Xcode, not the Command Line Tools (CLT lacks Swift Testing).
  `xcode-select -p` must point inside `Xcode.app`; otherwise prefix with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Git tests build throwaway repos with `TestRepo` in `TestSupport.swift`.
- Wait for GRDB observation by polling (~20 ms interval, 5 s timeout), never a
  fixed sleep.
- Snapshot tests set window appearance explicitly and poll for settled pixels.
  Use fully offscreen windows and programmatic APIs only — no OS-level
  synthetic clicks or keystrokes. Run a suspected flake in isolation too.
- Terminal PTYs start only once attached to a view; terminal tests need a real
  offscreen `NSWindow`.
- Use a per-test `UserDefaults(suiteName:)`; leaked `settings.appearance.*`
  keys contaminate snapshots. Inject sound playback as a no-op.

## Conventions

- Conventional Commits with a scope, e.g. `fix(subagents): ...`.
- Work on a feature branch; merge current `main` into it, verify there, then
  fast-forward `main`. There is no remote; diff against local `main`. Don't
  push or publish without explicit permission.
- Native-first UI: standard controls and system text, keep VoiceOver and
  reduced-motion support. Justify any custom replacement of a system control.
- Maintained, common dependencies are fine; minimising dependency count is not
  a goal.

## Gotchas

- **Only `Terminal/GhosttyBridge.swift` may `import GhosttyTerminal`.** All
  libghostty interop stays there.
- **Don't bump libghostty-spm incidentally.** Its embedding API is unstable
  upstream (spec §12); a bump is a deliberate, reviewed change.
- **Never relaunch, replace, or quit a running B-Side** — it may host the Pi
  session doing the work. Rebuild and let the user reopen it.
- **Ghostty sees shortcuts before the AppKit menu.** A new app shortcut that
  collides with a Ghostty binding must be added to
  `GhosttyBridge.appOwnedKeybinds`; an unbind alone fails under Pi's kitty
  keyboard mode. `MainMenuKeyRouter` offers Cmd/Ctrl keys to the menu first.
- **One invalid Ghostty config directive rejects the whole config.** Validate
  against a real host's `lastConfigurationIssue`, not the generated text. Pass
  colours via `theme:`; `terminalConfiguration:` colours can be overwritten.
- **Appearance follows the chosen theme, never macOS light/dark.** Theme each
  separate window and sheet explicitly.
- **Keep `.commands` on the `WindowGroup`**, not `Settings`, or menu entries
  duplicate and shortcuts go dead.
- **Keep `SubagentPaneStore.maxPanesPerTask = 4`.** Higher counts crashed
  libghostty in tests.
- **Resume Pi by transcript path**, never by falling back to
  `pi --session-id <uuid>` in another cwd — Pi silently creates an empty
  session. Transcripts can reach 40 MB; don't scan them on the main actor.
- **Guard async terminal creation** (`ConversationLaunchGate` in
  `MainAreaView.swift`) or duplicate conversations and orphaned PTYs appear.
- **Don't write observed properties in a SwiftUI `body`, and don't capture
  state in `onAppear` closures** for click/tick handlers — both caused render
  loops or stale behaviour in the subagent strip.
- **`GitCLI` must wait for EOF on both pipes and process exit**, or output
  truncates. Persist DB fields after each successful git step so partial
  failures don't desync state.
- **Legacy migration** (`DashNative` → `B-Side` app-support dir, `.dash/` →
  `.bside/` in project trees): on failure keep reading the legacy location;
  never create an empty destination that suppresses retries. Don't use real
  legacy projects as test fixtures — loading them migrates them.
- **Auto-rename changes a task's title and app-created branch, not its
  worktree directory** (`new-task-<4 hex>` stays).
- **After moving the checkout**, run `git worktree repair` and
  `swift package reset`; SwiftPM caches absolute XCFramework paths.
