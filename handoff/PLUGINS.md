# Plugins, skills and tools

Everything installed on the owner's Claude setup at the time of the handoff, grouped by how LifePath uses it. Install the same plugins on a new account where possible; if one is missing, carry on and tell the owner in one line.

## The plugin files themselves

The real plugin files sit on the owner's laptop in `handoff/private/plugins/` (git-ignored, because `prefskill` holds the owner's personal preferences and the repo is public):

- `installed/<name>.zip`: the exact installed version of every plugin (one zip per plugin, plus `anthropic-skills.zip` with the built-in skills such as `llm-council` and `deep-research`, and the Claude Code CLI copies `superpowers-cli`, `page-check-cli`, `diagram-design`). These are the ones to install on a new account: in the Claude desktop app, upload the zip as a plugin (Customize → Plugins → upload); for Claude Code, unzip into a local marketplace folder.
- `downloads-originals/`: the zips the owner originally downloaded (some contain more than what was installed).

`bash handoff/update.sh` re-zips them (via `zip-plugins.ps1`) so they stay current.

## Built for the owner

| Plugin | What it does |
|---|---|
| `limit-pacer` 1.6.0 (the owner edits it themselves; newest zip in the Downloads folder, copy in `private/plugins/installed/`) | Paces work against the Claude plan limits in any project. Two hooks count actions (user messages and tool calls); burn is measured per 100 actions, not per hour; check-ins come every 80 actions when both limits are far and down to every 5 when one is close. Readings live in `<project>/.claude/limit-pacer/<account hash>.json` (git-ignored, per account). Pace levels: watch (≥ 60% or < ~400 actions left: milestones, skip optional rounds), tight (≥ 85% or < ~150: ship a testable release before the limit), nearly out (≥ 95% or < ~40: commit, push, refresh the handoff). Since 1.6.0 those levels apply only when the weekly cap is the closer limit; when only the 5-hour window is close it just pauses work, so the guidance is: keep going, push finished work, give the owner a one-line heads-up, resume after the reset, no handoff. In the desktop app Claude refreshes readings with `get_usage` and `pacer.mjs record`. Limits never lower the project's goals. |

## Used so far

| Plugin / skill | How it's used |
|---|---|
| `superpowers:brainstorming` | Turning ideas into the design spec |
| `superpowers:writing-plans` | One implementation plan per stage (`docs/superpowers/plans/`) |
| `superpowers:subagent-driven-development` | The build loop: implementer per task, task review, fix rounds, final review |
| `superpowers:executing-plans` | Stage 0 was built inline with it |
| `superpowers:test-driven-development` | Every Core change: test first, see it fail, implement |
| `superpowers:verification-before-completion` | No "done" without test/CI evidence |
| `superpowers:requesting-code-review` (its `code-reviewer.md`) | Instructions for every whole-branch final review |
| `superpowers:finishing-a-development-branch` | Merging and releasing a stage |
| `superpowers:dispatching-parallel-agents` (pattern) | Parallel tasks in separate git worktrees |
| `ponytail:ponytail` | Owner's standing rule: smallest complete code; in every implementer/reviewer context |
| `prefskill:prefskill` | Loads the owner's writing preferences on every message (a hook requires it) |
| `prefskill:fresh-read` | When revising documents the owner reads |
| `dutch-native:dutch-native` | Writing Dutch (NL) for the owner |
| `anthropic-skills:deep-research` | The research report on battery-efficient tracking (`reports/`) |
| `page-check` (hook) | Runs on every written file; flags wording that reads like a change log |
| Built-in tools: Agent (subagents, worktrees), WebSearch, web-fetch agent, Bash/PowerShell, TaskStop, SendMessage | Building, research, CI polling, coordinating agents |

## Planned for later stages

| Plugin / skill | Planned use |
|---|---|
| `impeccable:impeccable` (+ its finish-reviewer and documenter agents) | Stage 6 design: visual direction with the owner, restyling all screens, a DESIGN.md |
| `humanizer:humanizer` | Final pass on all user-facing copy (onboarding, settings texts, status messages) |
| `dataviz` | Stage 4 stats screen: charts, stat tiles, colours that work in light and dark |
| `artifact-design` / Artifact tool | Showing the owner design mockups and comparisons in stage 6 |
| `ponytail:ponytail-review` / `ponytail:ponytail-audit` | Whole-branch reviews and a repo-wide audit before a 1.0 |
| `code-review` / `security-review` | Extra review before major releases (privacy is a core principle) |
| `superpowers:systematic-debugging` | When health reports from the phone show a bug |
| `anthropic-skills:llm-council` | Pressure-testing big product decisions if the owner wants several angles |
| `explainer-pages:explainer-page` | If the owner wants a readable explainer of how LifePath works |

## Installed, possibly useful extras

| Plugin / skill | Possible use |
|---|---|
| `diagram-design` | Architecture or data-flow diagrams for the docs |
| `artifact-diagramming`, `artifact-capabilities` | Interactive pages (e.g. a health-report viewer) |
| `anthropic-skills:docs` / `doc-coauthoring` | A shareable written spec or user guide |
| `anthropic-skills:pdf` | Exporting a guide or report as PDF |
| `anthropic-skills:consolidate-memory` | Tidying Claude's memory notes for this project |
| `anthropic-skills:skill-creator` | Packaging the LifePath workflow as a reusable skill |
| `anthropic-skills:built-in-browser` / `chrome-browser` | Checking GitHub pages, SideStore docs |
| `reflect-skill:reflect` | Mid-project reflection on direction |
| `logic-reasoning` (argument-analyst, formal-logic-solver) | Checking tricky rules (e.g. pin logic) |
| `riff` (critique, copyedit, revise) | Polishing longer texts for the owner |
| `prose-mechanics`, `tekstanalyse`, `deepread`, `storytelling` | Text work; not needed for the app itself |
| `everyday-skills` (theme-factory, file-organizer, …) | `theme-factory` might help in the design stage |
| `run`, `simplify`, `fewer-permission-prompts`, `update-config`, `loop`, `schedule` | Claude Code housekeeping; `schedule` could run a periodic check |
| `caveman` | Terse replies if the owner asks |

## Installed, not relevant to LifePath

`enso-seo` (all SEO skills and agents), `web-perf-audit`, `litreview`, `archify`, `epicskill`, `morning`, `explain-usage`, `import-memory`, `setup-claude`, `comment-on-docx`, `docx`, `pptx`, `xlsx`, `google-workspace`, `canvas-design`, `claude-api`, `plugin-authoring`, `keybindings-help`, `statusline-setup`, `init`, `raffle-winner-picker`, `invoice-organizer`, `tailored-resume-generator`, `domain-name-brainstormer`, `content-research-writer`, `meeting-insights-analyzer`, `image-enhancer`.

## Connected tools (MCP)

Gmail, Claude Docs, the visualize widget, Claude in Chrome, the built-in browser, scheduled tasks, PDF viewer, terminal. None are used by LifePath's build; never send project or personal data through them without the owner asking.
