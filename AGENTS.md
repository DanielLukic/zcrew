# zcrew

---

# 🪖 BOY SCOUT RULE

**LEAVE THE FILE CLEANER THAN YOU FOUND IT.**

When you touch a file for any reason, remove dead imports, unused variables, stale comments, and obvious debt that crosses your path. If you notice it while you're there, fix it. Do not file a follow-up ticket for what is a one-line cleanup right now.

---

# 🪟 NO BROKEN WINDOWS

**DO NOT SHIP "HARMLESS" DEBT.**

Unused imports, dead branches, TODOs without owners, half-finished tests, leftover scratch files — all are broken windows that signal it is okay to leave more. Every PR raises the bar. If you cannot fix it now, it does not ship.

---

# 🌲 WORKTREE WORKFLOW

**WORKERS NEVER EDIT THE LIVE ORCHESTRATOR TOOLING.**

The orchestrator's `.zcrew/{bin,lib}` is mounted read-only inside worker sandboxes for a reason: workers must not mutate the very tooling that runs the session. To do real work that touches these files (or any other source the worker is rewriting), the orchestrator creates a per-task git worktree:

```
git worktree add worktrees/<task-id>-<slug> -b <branch> <base>
```

Worktrees live under `worktrees/` (gitignored) inside the project root so the bx sandbox already sees them rw without any mount changes. The worker pane stays stable across tasks; the worker `cd`s into its assigned worktree, edits in place, runs tests, and commits to its task branch. The orchestrator cherry-picks / fast-forwards / merges into the integration branch, then tears the worktree down:

```
git worktree remove worktrees/<task-id>-<slug>
git branch -D <branch>
```

**No more patch files. No more host-side `patch -p1`. Workers do end-to-end task work; the orchestrator orchestrates.**

---

Cross-tool skill entrypoints for the zcrew multi-agent CLI and its human-facing helper commands.

## zcrew

Reference skill for orchestrating panes, dispatching work, and verifying outcomes with `zcrew`.
See: `.agents/skills/zcrew/SKILL.md`

## zspawn

Human shortcut for spawning an agent pane from Claude Code.
See: `.claude/skills/zspawn/SKILL.md`

## zsend

Human shortcut for sending a message to a registered pane from Claude Code.
See: `.claude/skills/zsend/SKILL.md`

## zpanes

Human shortcut for listing registered panes from Claude Code.
See: `.claude/skills/zpanes/SKILL.md`

## zsync

Human shortcut for reconciling the pane registry with live panes from Claude Code.
See: `.claude/skills/zsync/SKILL.md`

## zname

Human shortcut for renaming a registered pane from Claude Code.
See: `.claude/skills/zname/SKILL.md`

## zclose

Human shortcut for closing a registered pane from Claude Code.
See: `.claude/skills/zclose/SKILL.md`
