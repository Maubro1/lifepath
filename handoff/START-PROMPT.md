# Start prompt for a new Claude session

Paste the text below into a new Claude Code session opened on `C:\Users\mtska\Downloads\Lifepath 2.0`.

```
You are taking over LifePath, my private iPhone location-diary app, from another Claude session. I'm not a programmer: you make every technical decision yourself (code, git, branches, merges, releases) and never ask me about them. Ask me only about things on my phone, my accounts, how something should look or feel, and big product decisions. I write in Dutch or English; answer in the language of my message (Dutch = Netherlands Dutch).

Start like this:
1. Read handoff/README.md and follow it exactly, including everything in handoff/private/ (my writing preferences, your memory notes about me, the build workspaces, the council transcript). Then read handoff/STATE.md, HOW-WE-WORK.md, PLUGINS.md, ORIGINAL-BRIEF.md, robustness-audit.md and the spec's Principles section.
2. Check which plugins from handoff/PLUGINS.md this account has. Install missing ones from the zips in handoff/private/plugins/installed/ if you can; otherwise tell me in one line which ones I should upload myself (Customize → Plugins).
3. Load and use: prefskill (if it isn't installed, read handoff/private/preferences.md in full and follow every line of it in every message), superpowers (subagent-driven-development, test-driven-development, verification-before-completion, writing-plans), ponytail, and dutch-native when you write Dutch.
4. Copy handoff/private/sdd/* to .superpowers/sdd/ if .superpowers is missing. git fetch, check out branch `places`, run the local Core tests (pwsh -NoProfile -File scripts/test-core.ps1), then check CI on the branch head (bash scripts/ci-wait.sh <sha>) and fix any build errors: several recent commits only compile on CI and were never confirmed.

Then keep building stage 2b in this order, as STATE.md describes:
- 1c: the diary stores realDays and recentDurations (additive migration, or rebuild from the visit table).
- R: the Critical and Important items from handoff/robustness-audit.md (a minimal "Save a backup" button, a visible "Not saving since" status, protected-data handling after reboot, the "open LifePath once after a SideStore refresh/update" hint, etc.), plus the clearer setting names and one-line descriptions. My own health report confirmed that installing an update leaves a gap until I open the app.
- Task 4 (calm resting at visible pins), Task 5 (pins on the map), then the final whole-branch review and release v0.3.0-preview.1 (version 0.3.0, build 7) as an installable GitHub pre-release.

How I want you to work: follow the principles in the spec (life-long and complete, honest, precise, private, free, cool and battery-light, smallest complete code). The app and its data must survive crashes, updates and iOS kills. Be fast and token-efficient: tests and reviews only at critical moments (before merging, before a release, for risky data or recording logic), not after every change. Never put my name, email or personal data in commits or the public repo. Never claim work is running unless an agent or background job really is. When my usage limit gets close to 95%, refresh the handoff folder (bash handoff/update.sh, update STATE.md, commit on `places` and `main`).

When you've read everything, tell me in plain Dutch what you picked up and what you're doing next, then start.
```
