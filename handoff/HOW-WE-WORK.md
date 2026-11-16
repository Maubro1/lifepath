# How we work

## The owner

- Not a programmer. Claude makes every technical decision (including git: branches, merges, releases) and never asks about them. Ask only what the owner can answer: things on the phone, accounts, how something should look or feel, and big product decisions.
- Writes in English or Dutch; answer in the language of their message. Dutch is Netherlands Dutch (load the `dutch-native` skill).
- Wants many design questions, but only in the design stage (stage 6).
- **Top priority: accuracy, efficiency (battery) and a cool phone, together.** Every design, ruling and review checks these three first; when they conflict, look for a design that serves all three before trading one away, and tell the owner what any trade costs.
- Wants the strongest proven algorithms that stay lightweight ("very smart, efficient, high level").
- Values honesty: never claim work is running unless an agent or background job really is; if you stop, say "nothing is running until you reply".
- When away, keep building stage after stage; collect phone checks and big decisions for their return.
- Wants speed and token efficiency: tests and reviews only at critical periodic moments (before merging a stage, before a release, for risky data or recording-engine logic), not after every change. Skip scoped re-reviews when fixes are precise.
- The app and its data must survive crashes, updates and iOS kills; every setting needs a clear name and, where needed, a one-line description.
- Uses the `limit-pacer` plugin (see PLUGINS.md) to plan releases and handoffs around the 5-hour and weekly limits, so a testable build is ready before a limit hits and the owner can try it while waiting.
- Wants Claude to keep an eye on the limits throughout. The routine: read usage (`get_usage`) and record it with the pacer at the start of a session and at every milestone (after a task merge, before a release); tell the owner the numbers when asked (percent used, time to reset, roughly how many actions are left). When the 5-hour window runs low, publish a working build first so the owner can test while it resets. At about 95% of the weekly limit (not the 5-hour window, which only pauses work until it resets), refresh this folder: `bash handoff/update.sh`, update STATE.md, commit on `places` and `main`.
- Publishes an installable pre-release on GitHub at every milestone that changes what the phone app does.
- Their writing preferences (tone, banned phrases, structure) are in `private/preferences.md` (from the `prefskill` plugin). Follow them in every message.

## Principles (binding; full text at the top of the spec)

Life-long and complete (reduce detail, never coverage; nothing recorded is hidden by a limit) · honest (no invented data; gaps stay gaps) · precise · private · free · out of the way · cool and battery-light · smart but lightweight · smallest complete code (ponytail). Every ruling, cap or shortcut is checked against these before it's made; reviewers are told to flag violations.

## Process (superpowers skills)

1. New feature → `superpowers:brainstorming` (spec section) → `superpowers:writing-plans` (a plan per stage in `docs/superpowers/plans/`).
2. Execute with `superpowers:subagent-driven-development`: one implementer subagent per task (models: sonnet for mechanical tasks, opus for algorithms/integration), then a task reviewer, fix rounds with scoped re-reviews, then one whole-branch final review on opus, one fix wave, scoped re-review, release.
3. Each plan has a workspace `.superpowers/sdd/<plan>/` with `progress.md` (the ledger: every task completion, ruling with its cost-if-wrong, deferred minor) and `context.md` (what every subagent reads first: branches, tests, CI, principles, ponytail, report rules).
4. Implementers work in git worktrees (`isolation: worktree`) when running in parallel; create worktrees one at a time (parallel creation collides). The controller merges branches, reconciles conflicts, runs local tests, pushes.
5. TDD (`superpowers:test-driven-development`): test first, see it fail, then implement. Core runs locally; Diary and the app only on CI.
6. `superpowers:verification-before-completion` before claiming anything works.
7. At the end of a stage: write `docs/decisions/<stage>.md` from the ledger's rulings and deferred minors, bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`, merge to `main`, tag `vX.Y.Z-preview.N`, push the tag (CI publishes the Release with the IPA), delete merged branches and worktrees.

## Skills and plugins used (install these on a new account; full inventory in PLUGINS.md)

| Plugin / skill | Used for |
|---|---|
| `superpowers` (brainstorming, writing-plans, subagent-driven-development, executing-plans, test-driven-development, verification-before-completion, requesting-code-review, finishing-a-development-branch, systematic-debugging) | The whole build process |
| `ponytail` (ponytail, ponytail-review) | Smallest complete code; the owner asked for it explicitly |
| `prefskill` | Loads the owner's writing preferences every message (a hook asks for it) |
| `dutch-native` | Writing Dutch (NL) |
| `anthropic-skills:deep-research` | The battery research report |
| `humanizer` | Final pass on user-facing copy (onboarding, stage 6) |
| `impeccable` | Design stage (stage 6) |
| `page-check` | Runs automatically on written files (flags change-log wording) |

If a plugin isn't available on the new account, carry on and tell the owner in one line which one is missing.

## Tooling on this laptop (Windows 11, no Mac)

- **Repo**: `C:\Users\mtska\Downloads\Lifepath 2.0`, remote `https://github.com/Maubro1/lifepath` (public). Git identity in this repo: `LifePath <lifepath@users.noreply.github.com>` (never put the owner's name or email in commits). Commit trailer: `Co-Authored-By: Claude …` per the session's attribution reminder.
- **Local Core tests**: Swift 6.4.2 for Windows + Visual Studio 2022 Build Tools are installed. Run `pwsh -NoProfile -File scripts/test-core.ps1 [--filter XTests]`. If Swift binaries are missing, Avast may have quarantined them (IDP.Generic false positive): reinstall with `winget uninstall --id Swift.Toolchain -e` then `winget install --id Swift.Toolchain -e`, and ask the owner to add Avast exceptions for `%LOCALAPPDATA%\Programs\Swift`, the repo folder and `%LOCALAPPDATA%\Temp`.
- **CI** (`.github/workflows/ci.yml`, runner `macos-26`, Xcode 26.6): test job (Core + Diary tests) and build job (XcodeGen, unsigned archive, IPA packaging, Info.plist checks; releases on `v*` tags, pre-release when the tag has a suffix). Errors appear as annotations readable without login.
- **Waiting for CI**: `bash scripts/ci-wait.sh <commit sha>`. GitHub's anonymous API allows 60 calls/hour shared by all agents; the script uses ETags and waits out the limit. Don't let finished agents keep polling (stop them).
- **Swift package versions**: tools 6.2, platforms iOS 26 / macOS 15. GRDB from 7.1.0 is the only dependency.
- **Owner's install route**: SideStore (installed with iloader from Windows) + LocalDevVPN; weekly "Refresh All"; always the same Apple ID. See `docs/install.md`.

## Conventions

- Stored points are never modified; derived caches (smoothedPoint, tripLine, places) are recomputable.
- Heavy work only while the app is open or the phone is charging.
- Every shortcut gets `// shortcut: <limit>, <when to upgrade>`.
- Test fixtures are synthetic (the repo is public).
