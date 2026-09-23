# ShotDrop — agent guide (read this first)

> Every screenshot is instantly copied AND saved exactly where you want it.

This repo is built by a MacFleet team of Codex chats. Your role card is in `.fleet/roles/<role>.md`.
Coordination happens only through `python3 .fleet/coord.py` (run from the repo root).

## Who may edit what
- **implementor**: owns the repo. The only chat that edits code, docs/ROADMAP.md checkboxes, DEVLOG and DECISIONS.
- **everyone else**: repo is read-only. Write in your bus work dir (`python3 .fleet/coord.py paths --role <you>`).
- Nobody edits `.fleet/` except Shiv or Fleet Control.

## Docs
| File | What |
|---|---|
| docs/PRODUCT.md | what we're building and why |
| docs/TECH.md | how: APIs, architecture, permissions, risks |
| docs/ROADMAP.md | milestones with checkboxes (the implementor's fallback work list) |
| docs/DEVLOG.md | implementor's running log (one line per item) |
| docs/DECISIONS.md | judgment calls made without asking |

## Coordination cheat sheet
```
python3 .fleet/coord.py board                                  # team status, queue, latest build
python3 .fleet/coord.py inbox --role <me>                      # read (and mark read) my messages
python3 .fleet/coord.py send --from <me> --to <role|workers> --kind assignment|status|note|question|alert --subject "..." --body "..."   (or --body-file f)
python3 .fleet/coord.py report --from <me> --title "..." --body-file f --done   # worker deliverable -> report_manager, marks me WAITING
python3 .fleet/coord.py state --role <me> --set ACTIVE|WAITING|DONE|HUMAN_REQUIRED --note "..."
python3 .fleet/coord.py queue add --from report_manager --priority P0-P3 --title "..." --body-file brief.md
python3 .fleet/coord.py queue list | next | show --id N | done --id N --result ".." | block --id N --reason ".."
python3 .fleet/coord.py build --commit <sha> --app-path <.app path> --note "..."   # notifies qa + review
python3 .fleet/coord.py human --from <me> --ask "..."          # something only Shiv can do
python3 .fleet/coord.py paths --role <me>                      # where to put your files
```
The Stop hook keeps every registered chat moving: when you end a turn it hands you new work, messages or a heartbeat.
End turns normally. Don't write "waiting..." loops yourself.

## Subagents: use them aggressively
Every role fans out to Codex subagents whenever a task has parallel parts. That's how this team goes fast.
- Default 3-8 subagents per substantial task, up to ~15 for big sweeps (research surveys, full reviews, QA passes). Skip them for trivial one-step tasks.
- Brief each subagent narrowly: the exact question/job, which files it may read or edit, what to return (a concise summary, a patch, or a file path). You merge the results.
- Only the parent chat uses `coord.py` (send/report/queue/state). Subagents never touch the bus and never commit.
- Code-writing subagents (implementor only) must work on **disjoint files**. Two subagents never edit the same file. The implementor integrates, builds, tests and commits.
- Subagents running builds: only one `xcodebuild` at a time per project. Let the parent run the build.

## Engineering rules
- Swift 6, SwiftUI + AppKit, minimum macOS **14.0**. Apple Silicon first.
- **XcodeGen**: `project.yml` is the source of truth. `ShotDrop.xcodeproj` is generated and gitignored. Run `xcodegen generate` after changing targets/files.
- Bundle id prefix `com.macfleet.shotdrop` (Shiv may rename later).
- Layout: `Sources/ShotDrop/` (App/, Core/, Modules/, UI/), `Tests/ShotDropTests/`, `Resources/`, `Config/`.
- Build: `xcodebuild -project ShotDrop.xcodeproj -scheme ShotDrop -configuration Debug -derivedDataPath build build`
- Signing: put `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` (gitignored) when Shiv provides a team. An Apple Development identity keeps macOS permission grants (TCC) across rebuilds. Ad-hoc signing makes macOS forget grants after every rebuild.
- UI on `@MainActor`. Never block the main thread. Structured concurrency over GCD where practical.
- Energy matters: no busy polling, stop timers/animations when hidden or idle, pause on display sleep.
- Logging: `os.Logger(subsystem: "com.macfleet.shotdrop", category: ...)`.
- Put testable logic in `Core/`, with XCTest coverage for logic and every bug fix.
- Dependencies: SPM only, and only with a line in DECISIONS.md explaining why. Never copy GPL code.
- No `sudo`, no SIP changes, no deleting user files, no secrets in the repo. Anything needing admin rights -> `coord.py human`.
- Small commits: `feat|fix|chore|test|docs: summary (#queue-id)`. Never rewrite history.
