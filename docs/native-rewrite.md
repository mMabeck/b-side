# Native Rewrite Plan

A macOS-only Swift app for running Pi agent sessions. Native AppKit/SwiftUI throughout,
libghostty for terminals, git worktrees as the organising principle.

This document describes **what the app does**, not how it looks. It deliberately contains no
layout, sizing, font, colour or spacing decisions. Those are left to whoever builds the views,
with one constraint recorded in [Look and feel](#look-and-feel).

This is a personal-use tool. Where the Electron app was built to be shipped to strangers, this
one is not, and the scope below is cut accordingly.

---

## 1. Why rewrite at all

The Electron app works. The reasons to start over are structural, not cosmetic:

- **The terminal is the product, and it is the weakest layer.** Terminals are rendered by
  xterm.js inside Chromium. libghostty is a better terminal engine by a wide margin, and it is now
  genuinely embeddable in a Swift app.
- **Native module ABI churn is a recurring failure mode.** `better-sqlite3` and `node-pty` must be
  rebuilt against Electron's Node ABI on every install, and when that slips the app starts but
  every IPC call fails. A Swift app linking a static library and SQLite has no equivalent class of
  bug.
- **The feature surface has outgrown its purpose.** The Electron app carries skills registries,
  plugin marketplaces, Azure DevOps work items, port allocation and dev-server supervision,
  telemetry, auto-update, project scaffolding and a setup wizard. For personal use most of that is
  dead weight; see [Cut list](#9-cut-list).
- **Cross-platform is not being used.** Linux and Windows targets exist and are not exercised.
  Dropping them unlocks the native path entirely.

The rewrite is not justified by performance of the UI shell. It is justified by terminal quality
and by the smaller, simpler thing that comes out the other side.

---

## 2. Shape of the app

One window. Three regions plus a terminal:

- **Left sidebar** — projects and the tasks inside them, each with a status indicator and a
  summary of its git state. This is the navigation surface and the at-a-glance dashboard.
- **Main area** — the selected task's terminal: the coding agent running in that task's worktree.
- **Right sidebar** — two tabs. **Source Control**, modelled closely on VS Code's SCM view: a list
  of changed files, staging, a commit message field, commit. And **Subagents**, a live view of the
  child agents the current task has spawned (see §6).
- **Terminal drawer** — a *separate* terminal, distinct from the agent terminal, for the user's own
  shell in the same worktree.

Settings live in a standard macOS settings window, not an in-window panel.

Both sidebars and the drawer are individually collapsible, and that state persists.

---

## 3. Domain model

Three entities. Everything else is derived or transient.

### Project

A local git repository the user has added. Records its path, display name, the remote, and the
**base ref** — the branch that tasks branch from and are compared against (usually `main`).

Projects are added by choosing an existing directory or cloning a URL. A non-git directory can be
`git init`-ed on add.

### Task

A unit of work. Owns a **branch** and, normally, a **worktree**. Records:

- name (user-provided, or generated from the first prompt — see [Auto-naming](#auto-naming))
- branch name and whether the app created that branch (governs whether deleting the task may
  delete the branch)
- worktree path, or the project path if the task runs in-place
- which agent harness to run and with what permission level
- an optional context prompt prepended to the agent's first message
- optional per-task setup/teardown commands
- archived flag and a manual sort position

Tasks are the rows in the left sidebar. A task is long-lived: it survives app restarts, keeps its
terminal scrollback, and is archived rather than deleted when finished.

### Conversation

A task may have more than one agent session over its life. A conversation records one session:
its transcript file on disk, when it started, and whether it is the active one. This exists so
"resume the agent in this task" has a well-defined meaning and so history survives.

### Persistence

SQLite via **GRDB**. A small local database, plain SQL migrations, no ORM ceremony. SwiftData is
rejected: its migration story is worse for a hand-tuned schema and it fights value-type models.

Cascading deletes from project → task → conversation, as today.

The database and terminal snapshots live under the app's Application Support directory.

**Import path:** a one-time import from the Electron app's database, so existing projects, tasks
and branch associations carry over. Worth doing once; not worth maintaining.

---

## 4. Branches and worktrees

This is the core of the app and should be the most carefully built part.

### Creating a task

Creating a task means, in order:

1. Resolve the base ref (project default, overridable per task).
2. Create a branch from it, with a name derived from the task name.
3. Create a git worktree for that branch at a path outside the repository, in a sibling
   `worktrees/` directory keyed by a slug of the task name.
4. Copy across git-ignored files the worktree needs but git will not provide — `.env` and similar.
   Without this, a fresh worktree is not runnable for most projects.
5. Run the project's setup commands in the new worktree (dependency install, etc.), streaming
   output somewhere visible, without blocking the UI.

Steps 4 and 5 are the ones that make worktrees actually usable and are easy to underestimate.

### Starting from existing work

A task can also be created from a branch that already exists — a colleague's branch, a PR, an
abandoned local branch. In that case no new branch is created; a worktree is attached to the
existing branch.

The app must know which branches are **already checked out** in the primary repo or another
worktree, because git refuses to check a branch out twice. This needs to be surfaced when picking
a branch, not discovered as an error.

### Finishing a task

There is no built-in merge. The app exposes primitives — push, compare against base, open the
remote in a browser — and merging happens through the forge. What the app does provide:

- **Branch sync status** per task: ahead/behind counts against the base ref, and whether the branch
  has been merged. This is what drives the "finished" status in the sidebar.
- **Archive**, which hides the task and optionally removes the worktree, keeping the branch.
- **Delete**, which removes the worktree, runs teardown commands, and offers to delete the local
  branch — only if the app created it — and the remote branch.

Removing a worktree must run teardown before deleting the directory, and must `git worktree prune`
afterwards.

### Worktree hygiene

Worktrees are created and destroyed constantly, and git's metadata drifts. The app should prune on
launch and detect worktrees whose directories have vanished.

The Electron app pre-creates a spare worktree per project so new tasks start instantly. **Do not
port this initially.** It is a latency optimisation with real complexity (orphan sweeping, stale
reserve expiry) and it should only come back if task creation actually feels slow.

---

## 5. Task status

A task's status is the single most important thing the sidebar communicates. Four states:

| State | Meaning |
| --- | --- |
| **Running** | The agent is working. |
| **Needs attention** | The agent is waiting on the user — a permission prompt, a question, or an error. |
| **Idle** | The agent is alive but has nothing to do; the user's turn. |
| **Finished** | The branch is merged into base, or the task is archived. |

"Needs attention" is the state the whole app exists to surface. It must be visible without
selecting the task, and it should be what drives notifications.

### How status is detected

Not by scraping terminal output. The agent CLI reports its own state through hooks: the app runs a
small local HTTP server, passes its address to the agent process, and the agent POSTs lifecycle
events — prompt submitted, tool started, tool finished, permission requested, session stopped,
error, context compaction.

Three details that are easy to get wrong and expensive to rediscover:

- **Hook responses must have empty bodies.** Anything returned to the agent is liable to be
  injected into its conversation context.
- **A question to the user is "needs attention", not "running".** The tool-start event for the
  agent's ask-the-user tool must be special-cased, or the app will report a blocked agent as busy.
- **There must be a safety valve.** If a task is marked running or waiting but has produced no hook
  event *and* no terminal output for several minutes, force it to idle. Hooks do go missing —
  crashed processes, failed hook scripts — and without this, tasks get permanently stuck showing
  the wrong state.

### Notifications

Standard macOS user notifications on transitions into "needs attention" and on agent completion.
Clicking one selects the task. Off by default per-project would be over-engineering; a single
global toggle is enough.

### Auto-naming

When the user sends the first prompt in a freshly created task, generate a short task name from it
and rename the task, once. Guard against concurrent first-prompt events triggering two generations
for the same task.

---

## 6. Terminals

Two terminals per task, both libghostty surfaces — plus one more per running subagent, split into
the agent terminal's area (see [Subagents](#subagents-and-replacing-tmux)):

- the **agent terminal** — the coding agent CLI, spawned directly, running in the task's worktree
- the **shell terminal** — a plain login shell in the same worktree, for the user

Both must survive switching between tasks. Selecting another task and coming back shows the
session exactly as it was, still running.

### Embedding libghostty

The practical route is `libghostty-spm`, which ships a prebuilt `GhosttyKit.xcframework` plus a
`GhosttyTerminal` layer with AppKit and SwiftUI terminal views, an exec backend that owns the pty,
input handling, bundled shell integration, and a large theme collection. Building the xcframework
from the Ghostty source tree by hand is possible but means pinning a Zig toolchain and carrying a
~140 MB static archive; not worth it here.

What this buys, for free, that currently has to be maintained by hand:

- terminal emulation, GPU rendering, font handling, ligatures
- pty ownership and process lifecycle
- keyboard encoding, including the Kitty protocol; bracketed paste handled correctly as a distinct
  path from keystrokes
- selection, clipboard, scrollback
- **reading the user's own `~/.config/ghostty` config**, so the terminal matches their real terminal
  without the app defining any of it
- shell integration, including prompt marks — which gives prompt-to-prompt navigation

What the app still owns:

- deciding what process to spawn, with what environment and working directory
- supervising that process and restarting/resuming it
- persisting scrollback across app restarts
- interpreting agent hooks (which travel over HTTP, not the terminal)

### Many surfaces at once

Dozens of concurrent sessions is a supported pattern. Surfaces that are not visible are marked
not-visible rather than torn down: they keep their grid, scrollback and session, and simply stop
rendering. This maps exactly onto task switching.

Several existing apps do essentially this shape — native macOS terminals organised around agents
and worktrees — so this is not unexplored ground.

### Scrollback persistence

Terminal contents must survive quitting the app. libghostty-vt provides a snapshot API that
encodes terminal state and restores it incrementally, which is a direct replacement for the
current serialize-to-JSON approach.

Whatever the mechanism, keep the existing guard rails: cap the size of a single snapshot, cap total
snapshot storage, and prune oldest-first. Unbounded snapshot growth across many tasks and many
restarts is a real problem, not a theoretical one.

### Search and links

Both are provided by the terminal engine rather than hand-built: libghostty-vt exposes scrollback
search with find-bar-style match navigation and viewport highlights, and OSC 8 hyperlinks are
handled natively.

Clickable `file:line` references that are *not* OSC 8 — the ones agents emit as plain text — need a
small amount of app-side work: match them in the terminal's text and open them in the user's
editor. This is worth keeping; it is used constantly.

### Subagents, and replacing tmux

**The nested tmux session should go away.** It costs a generated tmux config, a per-task socket,
environment sanitisation, stale-identity stripping and explicit teardown on every kill path.

It exists for exactly one reason. The agent's subagent extension checks whether it is running
inside a wrapped tmux session and, if so, runs `tmux split-window -d <command>` to give each child
agent its own pane; otherwise it falls back to headless. That check is a single hard-coded
condition, not a pluggable surface API — so "support a different surface" means teaching the
extension a second backend.

The contract being satisfied is small, which is what makes replacement tractable: *run this command
detached, somewhere visible, and tell me nothing.*

**Decision: the app splits its own terminal area natively. Children appear as panes beside the
parent, in the same view, and the app also renders a card per child in the right sidebar. There is
no tmux, and no interim tmux stage.**

The options below are kept as the reasoning behind that choice, followed by what was built and
measured along the way.

Five options, best first:

**1. Headless (the default, and the day-one answer).** Subagents run as ordinary child processes
and the parent shows inline tool rows. Combined with the extension's background-job mode, work is
already non-blocking: a detached subagent returns a job id immediately and delivers its result as a
follow-up message later. Nothing is rendered into the main terminal and nothing blocks. Zero work,
zero risk. The only loss is live visibility into what a child is doing.

**2. Host-owned native surfaces (the target).** Write a second backend for the subagent extension
that, instead of shelling out to tmux, asks the host app to spawn the child command — over the same
local HTTP channel already used for status hooks. The app creates a libghostty surface per subagent
and shows them in a subagent area beneath the task's main terminal, or as tabs alongside it.

This is the clean native answer. Each child is a real terminal surface with real scrollback, the
app knows the full parent→child tree so it can show subagent status in the sidebar, and there is no
multiplexer in the process tree at all. It is also roughly what cmux did, via an environment
variable identifying its surface — so the shape is proven.

Cost: one Pi extension backend, plus a spawn endpoint in the app. Pi is extended rather than
patched as a matter of course here, so this is ordinary work, not a fork.

**3. tmux control mode.** Keep tmux as the process multiplexer but attach with `-CC`, so tmux
reports its panes over a control protocol and the app renders each one as a native surface instead
of drawing tmux's own output. iTerm2 has done this for years, and Ghostty has control-mode support
in its terminal layer.

Attractive because the subagent extension needs *no* changes — it keeps calling `split-window`. But
Ghostty's control-mode support has documented gaps that were still being filled through 2026
(bootstrap batching, layout-change resize, zoom handling, several commands), the protocol is fiddly,
and it keeps tmux in the process tree — which was the thing worth removing. Worth knowing about;
not worth betting on.

**4. A read-only progress view.** Don't give subagents terminals at all. Render each child's output
as a read-only scrolling view, driven by `libghostty-vt` in parse-only mode so ANSI output still
looks right. Much cheaper than a pty per child, and for supervising rather than interacting it may
be all that is wanted. A reasonable middle step between options 1 and 2.

**5. Separate windows per subagent.** Native, trivial, and immediately unpleasant with more than
two children. Noted only to be dismissed.

#### What options 2 and 4 actually look like — verified, not theorised

Both were built and run against real subagents before choosing, using **agterm** (a native macOS
libghostty terminal with a control CLI) as a stand-in for the host app.

The subagent extension gained a second backend — `agterm-view.ts`, selected with
`PI_SUBAGENT_SURFACE=agterm` — mirroring the tmux backend exactly: same launch script, same
event and done files, with only the surface operations swapped. The whole diff is one new file
plus a three-line branch, because the seam is just two functions.

A parent Pi was told to fan out three explorer subagents concurrently. Result:

- Each child got **its own host session** in a dedicated `subagents` workspace, named
  `<agent>: <task>`, created without stealing focus from the parent.
- Each row carried a **status glyph** driven by the child's own lifecycle — active while working,
  blocked when it raised a question, completed when it finished. This is the piece that matters:
  which of several running children needs you, visible without opening any of them.
- The parent ran to completion and summarised all three results normally.
- The same three live sessions rendered as a **read-only grid** on demand — option 4, for free,
  over the identical sessions. No second mechanism.

It worked, and the **placement** was wrong — not the mechanism.

Putting each child in its own sidebar session scatters one task's work across surfaces the user has
to go and visit. That is a statement about where agterm chose to put sessions, not about host-owned
surfaces in general. A host that splits children into the *same* view gets the thing that makes
tmux panes good, with none of tmux's costs.

What the exercise established, and what carries over: the extension has a clean seam (two
functions), it already emits a structured event stream per child, and the extension-side backend is
around 200 lines.

#### Why not just keep tmux

tmux exists in the Electron app for one reason: xterm.js renders one PTY per terminal, so splitting
had to happen *inside* the PTY. That constraint does not exist natively — an app can host several
libghostty surfaces side by side itself.

Keeping tmux would mean the app spawns `tmux attach-session` and therefore sees **one PTY**, with
tmux drawing the panes inside it. The consequences are the reason it is rejected outright:

- the app has no idea children exist — no per-child status, no cards, nothing in the task row
- pane chrome belongs to tmux, not the app
- the entire wrapper stays: generated config, per-task socket, env sanitisation, stale-identity
  stripping, teardown on every kill path

The only thing it buys is that it works without writing the backend. That is not worth being blind
to every child, so there is no interim tmux stage.

#### The chosen design: native splits, plus cards

**Live view.** When a task's agent spawns children, the app splits that task's terminal area and
gives each child its own libghostty surface beside the parent. Children are visible together, live
and interactive, in the view you are already looking at. When a child finishes its surface closes
and the remaining ones re-balance.

The parent's own inline card for each child stays as Pi draws it — that is Pi's business, and it is
already good.

**Summary view.** The app also renders a card per child in the **Subagents** tab of the right
sidebar. This is not a duplicate of the panes; it does the jobs panes are bad at — five concurrent
children, runs that have already finished and want reading afterwards, and telling the task row in
the left sidebar that something is blocked. Each card shows:

- the agent and its task label, and the task's opening line
- a live tail of what the child is doing — the tool calls as they happen
- its state: working, blocked on a question, finished, failed
- a footer of run statistics: turns, tokens in/out, context used, model
- expand, to see the full run rather than the tail

The difference from the terminal version is presentation, not content: real text layout instead of
box-drawing characters, real truncation instead of ellipsised fixed-width lines, selectable and
scrollable, and a card that can grow without redrawing a terminal.

Cards persist after a child finishes, so a completed run can be read afterwards, and clear when the
task's conversation does.

**One backend serves both.** A third backend in the subagent extension — alongside `tmux` and
`agterm` — asks the app to run each child's command in a new surface, and reports that child's
lifecycle events to the app rather than drawing them anywhere. The app decides what to do with
that: open a split, draw a card, update the task row. Panes and cards are two renderings of one
feed, not two mechanisms.

Events travel over the local endpoint the app already runs for agent status hooks; subagent events
are more of the same. It reuses the seam the agterm backend proved.

This is also what lets the left sidebar mean something: a task with three children working is
meaningfully busier than one waiting on the user, and the app now has the data to say so.

**Scope, honestly.** The ~200-line figure is the *extension* side, measured. The app side is
additional and is the real work: surface lifecycle, split layout and rebalancing, focus routing
between parent and children, and a cap on how many panes open before extra children go
card-only. Call it a few hundred lines more. It is still a much smaller thing than the tmux wrapper
it replaces, and unlike that wrapper it leaves the app knowing what is running.

One inherited rule carries over regardless: **never set the environment variable that identifies a
cmux surface.** Doing so makes spawned CLIs misidentify their host.

---

## 7. Source control

The right sidebar, modelled on VS Code's SCM view. Scoped to the selected task's worktree.

### Operations

- **Status** — changed files, split into staged and unstaged, with change kind (added, modified,
  deleted, renamed, untracked, conflicted) and per-file line counts added/removed.
- **Stage / unstage** — per file, per selection, and all.
- **Discard** — per file, with tracked and untracked handled appropriately, and confirmation.
- **Add to .gitignore** — from a file's context menu.
- **Commit** — message field, commit, with output from pre-commit hooks streamed live and
  cancellable. Hooks that take thirty seconds and then fail are common enough that hiding their
  output is not acceptable.
- **Push**.
- **Diff** — click a file, see its diff.
- **Branch view** — everything committed on this task's branch since it diverged from base, as
  opposed to just uncommitted work. This is how you review what a task actually produced.
- **History** — the commits on this branch, and the ability to open any one of them read-only.

### Diff viewing

A native unified diff view, built from a standard text view with syntax-aware coloring of added
and removed lines. Not a side-by-side editor, not an embedded Monaco, not a web view.

This is a deliberate downgrade from the Electron app, which has a full diff editor with in-place
editing, blame, commit browsing and persistent per-line comments. For personal use, the diff view
needs to answer "what changed" and hand off to a real editor for anything else. Opening the file in
the user's editor at the right line is the escape hatch, and it should be one keystroke.

If a side-by-side view is wanted later it can be added; the comment system should not come back.

### Git implementation

**Shell out to the git CLI.** Not libgit2.

Worktree support in libgit2 bindings is thin and the app's most important operations are worktree
and branch operations. The git CLI is the reference implementation, always matches what the user
sees in their own terminal, and its porcelain formats are stable and machine-readable. The cost is
process spawning and parsing, which is irrelevant at this scale.

Parse `status --porcelain=v2 -z`, not the human-readable output. Enrich with numstat separately and
asynchronously; cap diff sizes and detect binary files, so a large file cannot freeze the UI.

### Live refresh

Watch the worktree for filesystem changes and refresh status. Coalesce events — agents write files
in bursts, and a refresh per write is unusable.

---

## 8. Native UI decisions

The bias is toward plain, standard, system-provided controls. Anything that requires a custom
drawing pass should be justified.

- **Sidebar:** `NSOutlineView` in source-list style, hosting projects with tasks nested beneath.
  SwiftUI's `List` is more pleasant to write but `NSOutlineView` is better at large, frequently
  updating, per-row-status lists with context menus, drag reordering and keyboard navigation. This
  list is the app's most interacted-with surface; spend the complexity here.
- **Source control pane:** standard table/list plus a standard text view for the commit message.
  SwiftUI is fine here — the list is small and the interactions are simple.
- **Settings:** a standard SwiftUI `Settings` scene. Tabs for General, Agent, Git, Terminal,
  Notifications.
- **Window structure:** `NSSplitViewController` with collapsible sidebars, or SwiftUI
  `NavigationSplitView`. Either is acceptable; the split behaviour is standard.
- **Terminals:** the terminal view from `GhosttyTerminal`, hosted directly. libghostty surfaces are
  ordinary views and coexist with other AppKit views in the same window without trouble — the
  z-order problems that make this impossible under Electron do not exist here.
- **Menus and keyboard:** a real menu bar with real key equivalents, and full keyboard navigation of
  the task list. This is most of what "feels native" actually means.

### Look and feel

One constraint, stated once, because it is a real preference and not a styling detail:

**Use system-standard text and system-standard controls.** No hairline-weight fonts, no
dashboard-style metric readouts, no chrome that exists to look modern. If a piece of information is
worth showing it should be legible at a glance in the system font; if it is not worth showing, cut
it.

Specifically: the token/context/cost readouts from the Electron app are not carried over. See the
cut list.

---

## 9. Cut list

Everything below exists in the Electron app and is deliberately not rewritten. This is most of the
point of the rewrite.

**Cut outright:**

- Skills registry — browsing, installing, uninstalling agent skills
- Plugin marketplaces and the plugin catalogue
- Extension/agent/command/hook visibility overrides
- Azure DevOps work item integration
- Per-task port allocation, port liveness probing, dev-server start/stop/logs supervision
- The setup wizard
- Project scaffolding (running `create-*` template CLIs in-app)
- The managed external toolchain downloader
- Telemetry
- Auto-update — already disabled in this fork
- Remote control / mobile viewing
- Token and cost accounting, usage dashboards, rate-limit displays, context-usage indicators
- Diff editor comments, blame, in-place editing
- The reserve worktree pool
- Multiple drawer tabs per task

**Keep, reduced:**

- GitHub integration reduced to: create a task from an issue or PR, and open the current branch's PR
  in a browser. No in-app PR list, no issue search UI beyond what task creation needs.
- Agent harness abstraction reduced to the two harnesses actually used, selected in settings.
- Per-project configuration reduced to a small file in the repo holding setup/teardown commands and
  task defaults.

If any of these turn out to be missed, they can be added back one at a time, deliberately.

---

## 10. Dependencies

The guiding rule is that a personal tool should be able to sit untouched for a year and still build.
That does **not** mean minimising the dependency count. It means every dependency should be the
obvious, widely-used choice for its job — the one most people would reach for, with an active
maintainer and a long history — so that it is still there and still working in a year.

A popular library is usually safer than hand-rolled code. What is not safe is a clever, niche, or
recently-fashionable package doing something the platform or an established library already does.
The test for adding one is "is this the obvious choice?", not "can I avoid it?".

**Core dependencies:**

| Need | Choice | Why |
| --- | --- | --- |
| Terminal | **`libghostty-spm`** (`GhosttyTerminal`) | Prebuilt XCFramework via SwiftPM, AppKit/SwiftUI views, exec backend owning the pty, bundled shell integration. The alternative is building the framework from Ghostty source with a pinned Zig toolchain. |
| Persistence | **GRDB** | See below. |

**Persistence: GRDB, not SwiftData.** The data here is a handful of small relational tables with
foreign keys and cascades, queried on every UI update, plus a one-time import from an existing
SQLite database. That is SQLite's home ground.

GRDB is a mature, thin, type-safe layer over SQLite by a long-standing maintainer. It gives explicit
versioned migrations, plain value-type records, real SQL when wanted, and database observation for
driving the UI. SwiftData is an ORM with an opaque store, a migration story that is weaker for
hand-written schema changes, model-design constraints that push toward reference-type models, and a
history of behaviour changing between OS releases — the opposite of "builds untouched in a year".
Raw SQLite via C is viable but means hand-rolling migrations and result mapping for no gain over
GRDB.

The Point-Free `SQLiteData` / `sharing-grdb` layer on top of GRDB is a reasonable thing to add later
if the SwiftUI binding boilerplate becomes annoying. It is not needed to start.

**Where the platform is already the obvious choice, use it:**

- **Git** — shell out to the `git` CLI. No libgit2, no SwiftGit2. Reasoning in §7.
- **Concurrency** — Swift structured concurrency and `async`/`await`. No Combine, no RxSwift.
- **UI** — AppKit and SwiftUI only. No layout libraries.
- **Settings** — `UserDefaults` / `@AppStorage`.
- **Logging** — `OSLog`.
- **Tests** — Swift Testing.
- **Notifications** — `UserNotifications`.
- **File watching** — FSEvents or `DispatchSource`.
- **Updates** — none. Build and install locally; no Sparkle.

**Reasonable to add when the need is real**, each being the conventional pick in its area:

- **Swifter** or **Vapor**'s HTTP layer for the hook server, if hand-rolling a local listener on
  `Network` proves tedious. Start with the platform; swap if it hurts.
- **Sparkle** if the app ever wants updates. Not needed while it is installed by hand.
- **Splash** or **tree-sitter** for syntax highlighting, if the diff view's added/removed line
  colouring turns out to be too plain to read.
- **KeyboardShortcuts** for user-rebindable global shortcuts, if that is wanted.

**Still not wanted:** anything replacing AppKit/SwiftUI layout, any reactive framework alongside
structured concurrency, any ORM on top of GRDB, and any dependency whose main appeal is that it is
new.

---

## 11. Build order

Each stage should leave a working app.

1. **Skeleton.** Window, three regions, settings window, database, projects list. No agents yet.
2. **One terminal.** Embed libghostty, spawn a shell in a project directory, prove input, resize,
   scrollback and config loading work. This is the highest-risk step; do it second, not last.
3. **Tasks and worktrees.** Create a task, create branch and worktree, copy ignored files, run setup
   commands, remove and clean up. No agent yet — verify the git layer on its own.
4. **The agent.** Spawn the agent CLI in the task's worktree. Session persistence and resume.
5. **Status.** Hook server, the four states, the safety valve, notifications.
6. **Source control.** Status, staging, commit with streamed hook output, unified diff, branch view.
7. **Subagents.** The extension backend, the spawn/event endpoint in the app, native splits in the
   agent terminal area, and the Subagents card tab. Depends on stage 5's endpoint already existing.
   Panes and cards ship together — they are one feed rendered twice, and splitting them across
   stages means building the feed twice.
8. **Persistence and polish.** Scrollback snapshots with size caps, window and selection state,
   keyboard navigation, menu bar.
9. **Import.** One-time migration from the Electron database.

Stages 2 and 3 are independent and can be built in parallel.

---

## 12. Risks

- **The libghostty embedding API is explicitly not stable.** The project's own documentation says
  so: the full embedding API is used primarily by Ghostty's own macOS app and may change
  significantly between releases. `libghostty-vt` is heading toward a stable tagged release; the
  surface API is not there yet. Mitigation: depend on the prebuilt Swift package rather than
  building from source, pin a version, confine every C call to a single file so an API break is one
  file's worth of work, and do not chase upstream releases.
- **All C interop lands on one boundary.** The runtime configuration is the whole contract: a
  handful of callbacks, one of which is an action bus carrying dozens of distinct action types.
  Getting its return values wrong silently swallows keybindings. Budget real time for this layer
  and keep a written table of which actions are handled.
- **Apple Silicon only.** The prebuilt framework is arm64. This is fine here but it is a permanent
  constraint, not a temporary one.
- **Diff viewing is a genuine regression.** Accept it, and make "open in editor" excellent to
  compensate.
- **Native splits are the one feature with no fallback.** Rejecting the interim tmux stage means
  subagents are not visible live until the app's own split handling works. The mitigation is that
  cards come from the same feed, so a half-finished split implementation still leaves children
  observable in the sidebar — build the feed and the cards first, splits second, within the same
  stage.
- **Rewrites stall at 80%.** The cut list is the defence. Resist re-adding features until the core
  loop — create task, agent works, review diff, commit, archive — is better than what exists today.
