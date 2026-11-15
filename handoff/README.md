# LifePath handoff: start here

This folder lets a fresh Claude session (on any account) pick up the LifePath project exactly where it stopped. Read the files in this order:

0. **[START-PROMPT.md](START-PROMPT.md)**: the prompt the owner pastes into a new session.
1. **This README**: what the project is, where everything lives, how to resume.
2. **[STATE.md](STATE.md)**: what is done, what was in progress at the last update, and the decisions the owner still has to make.
3. **[HOW-WE-WORK.md](HOW-WE-WORK.md)**: the owner's working agreements, the process and the tooling on this laptop.
   **[PLUGINS.md](PLUGINS.md)**: every installed plugin and skill: used so far, planned, possible extras, not relevant.
4. **[ORIGINAL-BRIEF.md](ORIGINAL-BRIEF.md)**: the owner's original description of the app, word for word.
5. **`docs/superpowers/specs/2026-11-14-lifepath-design.md`**: the full design spec. It starts with **Principles**; every decision is checked against them.
6. **[robustness-audit.md](robustness-audit.md)**: crash/update safety findings and proposed setting names; the next fixes come from here.
7. **[ledger-current-stage.md](ledger-current-stage.md)**: the build ledger of the stage in progress (every task, review, fix round and ruling).
8. **`private/`** (only on the owner's laptop, never committed): the owner's writing preferences, Claude's memory notes about the owner, the plugin zips (`plugins/`), the full build workspaces with every task brief and subagent context (`sdd/`; copy back to `.superpowers/sdd/` to resume), and the council transcript behind the pin-hiding rule (`council/`). Read them; they matter as much as the spec.

## What LifePath is

A private, free, always-on location diary for the owner's iPhone 15 Pro (iOS 26). It records where the owner goes all day in the background, cleans up GPS wobble, and turns it into a life-long map, a timeline, stats, learned places and a tally of streets walked. No account, no server, nothing leaves the phone except OpenStreetMap street downloads. Built for €0 from a Windows 11 laptop with no Mac.

## Where everything lives

| What | Where |
|---|---|
| Code (public repo, code only, never personal data) | https://github.com/Maubro1/lifepath, local clone `C:\Users\mtska\Downloads\Lifepath 2.0` |
| Installable versions | GitHub Releases (tags `vX.Y.Z-preview.N` are pre-releases) |
| Design spec | `docs/superpowers/specs/2026-11-14-lifepath-design.md` |
| Plans per stage | `docs/superpowers/plans/` |
| Decisions made on the owner's behalf | `docs/decisions/` |
| Research report on battery-efficient tracking | `reports/Battery efficient location tracking.md` |
| Install/refresh guide for the owner | `docs/install.md` |
| Build ledgers (working files, git-ignored) | `.superpowers/sdd/<plan>/progress.md` (a copy of the current one is in this folder) |
| Claude memory for this project | `C:\Users\mtska\.claude\projects\C--Users-mtska-Downloads-Lifepath-2-0\memory\` (copy in `private/memory/`) |

## Code layout

- `Core/` (Swift package, Foundation only, unit-tested locally and on CI): filtering (`TrackFilter`, an IMM Kalman filter with Huber gating and Doppler fusion), the motion state machine (`MotionEngine`), backfill, trips, simplification, the RTS trip smoother (`TripSmoother`), heat grid, trip lines (level of detail), learned places (`Places`, `PlaceGrid`), status, health report.
- `Diary/` (Swift package, GRDB/SQLite, tested on CI only): the single diary file with migrations v1–v4. Migrations are additive only and never modify stored points.
- `LifePath/` (the iOS app, builds only on CI): `Recorder/` (CoreLocation + CoreMotion glue), `Map/` (map tab, smoothing service), `Places/`, `Features/` (onboarding, settings).
- `project.yml` (XcodeGen; the .xcodeproj is generated on CI), `.github/workflows/ci.yml`, `scripts/`.

## How to resume (for the new Claude)

1. Read everything listed above, including `private/`.
2. Load the skills named in HOW-WE-WORK.md (at minimum `superpowers:subagent-driven-development`, `superpowers:test-driven-development`, `ponytail:ponytail`, and `prefskill:prefskill` if installed; `dutch-native` when writing Dutch).
3. In the repo: `git fetch --all`, check `git branch -a` and STATE.md for the active branch, then `git checkout <active branch>`.
4. Run the local tests: `pwsh -NoProfile -File scripts/test-core.ps1` (Swift for Windows; see HOW-WE-WORK.md if it fails).
5. Recreate the workspace if `.superpowers/` is missing: copy `handoff/private/sdd/*` to `.superpowers/sdd/` (or, without `private/`, copy `handoff/ledger-current-stage.md` to `.superpowers/sdd/<plan basename>/progress.md`). Tasks marked `complete` there are done; resume at the first one that isn't.
6. Ask the owner about the open decisions in STATE.md before building anything that depends on them; keep building everything that doesn't.
7. Tell the owner plainly what you picked up and what happens next. They are not a programmer: explain in plain words, decide technical matters yourself.

## Refreshing this folder

Run `bash handoff/update.sh` to copy the latest ledger and memory files in. Then update STATE.md by hand (what's done, in progress, pending) and commit `handoff/` (the `private/` part stays local).
