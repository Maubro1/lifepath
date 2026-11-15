# Start prompt for a new Claude session

Paste the text below into a new Claude Code session opened on `C:\Users\mtska\Downloads\Lifepath 2.0`.

```
Hi! You're picking up LifePath, my private iPhone location-diary app, from another Claude session that ran out of credits. Everything you need is in this folder, so welcome aboard :) (The previous Claude wrote this prompt for me, which is why it sounds a bit technical.)

A bit about me: I'm not a programmer, so I'd love for you to make all the technical decisions yourself (code, git, branches, merges, releases) without checking with me. Please only ask me about things on my phone, my accounts, how something should look or feel, and big product decisions. I write in Dutch or English; just answer in whichever language I used (Dutch = Netherlands Dutch).

To get started:
1. Read handoff/README.md and follow it, including everything in handoff/private/ (my writing preferences, the previous session's memory notes about me, the build workspaces and the council transcript). Then read handoff/STATE.md, HOW-WE-WORK.md, PLUGINS.md, ORIGINAL-BRIEF.md, robustness-audit.md and the Principles section of the spec.
2. Check which plugins from handoff/PLUGINS.md this account has. If you can, install missing ones from the zips in handoff/private/plugins/installed/; otherwise just tell me in one line which ones I should upload myself (Customize → Plugins).
3. Please use these skills: prefskill (if it isn't installed, read handoff/private/preferences.md in full and follow it in every message), superpowers (subagent-driven-development, test-driven-development, verification-before-completion, writing-plans), ponytail, and dutch-native whenever you write Dutch.
4. If .superpowers is missing, copy handoff/private/sdd/* to .superpowers/sdd/. Then git fetch, check out the branch `places`, run the local Core tests (pwsh -NoProfile -File scripts/test-core.ps1) and check CI on the branch head (bash scripts/ci-wait.sh <sha>). A few recent commits only compile on CI and haven't been confirmed yet, so please fix any build errors first.

After that, the plan for stage 2b (STATE.md has the details):
- 1c: the diary stores realDays and recentDurations (an additive migration, or rebuild them from the visit table).
- R: the Critical and Important items in handoff/robustness-audit.md (a simple "Save a backup" button, a visible "Not saving since" status, handling the locked state after a reboot, the "open LifePath once after a SideStore refresh or update" hint, and so on), plus the clearer setting names with one-line descriptions. My own health report showed that installing an update leaves a gap until I open the app.
- Task 4 (calm resting at visible pins) and Task 5 (pins on the map), then the final whole-branch review and the release of v0.3.0-preview.1 (version 0.3.0, build 7) as an installable GitHub pre-release.

How I like to work: please follow the principles in the spec (life-long and complete, honest, precise, private, free, cool and battery-light, smallest complete code). The app and its data should survive crashes, updates and iOS kills. I'd like things to go fast and stay token-efficient, so tests and reviews only at the important moments (before merging, before a release, and for risky data or recording logic), not after every change. Please never put my name, email or other personal data in commits or the public repo. If you stop working, tell me honestly; only say something is running when an agent or background job really is. When my usage gets close to 95%, refresh the handoff folder (bash handoff/update.sh, update STATE.md, commit on `places` and `main`).

Once you've read everything, tell me in plain Dutch what you picked up and what you'll do next, and then go for it. Thanks, and have fun building!
```
