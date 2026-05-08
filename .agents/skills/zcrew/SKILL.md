---
name: zcrew
description: Reference for the zcrew multi-agent CLI. Use when you need to send messages between panes, spawn/close/rename agent panes, or list panes.
type: skill
---

# zcrew CLI Reference

Use `zcrew` to coordinate named panes inside a zellij session.

`zcrew spawn <agent> <name> [--model <model>]`
Starts a new named pane running `claude`, `codex`, or `pi`. Optional `--model` passes through to the launcher.

`zcrew send [--compact] <name> <message>`
Sends a message to a registered pane by name. `--compact` injects `/compact` before delivery — use when starting a new task on an existing agent.

`zcrew reply <message>`
For worker panes only. Sends a result, finding, blocker, or question back to `main`.

`zcrew close <name>`
Closes a registered pane and unregisters it.

`zcrew rename <old> <new>`
Renames a registered pane entry.

`zcrew claim [--replace]`
Registers the calling pane as `main` in the registry. Run this on session start in your orchestrator pane so workers can reply to you. Idempotent if you are already main. Errors if a different live pane is main; use `--replace` to take over intentionally.

`zcrew list`
Prints the current pane registry as JSON. Human users can also run `/zpanes`.

`zcrew sync`
Reconciles the registry with live panes. Human users can also run `/zsync`.

## How to invoke from an agent

Each agent type has exactly one reply mechanism — use only that one.

| Worker agent | Reply mechanism | What you do |
|---|---|---|
| **claude** | SessionStop hook auto-fires | Just write your result. The hook forwards your last assistant message to main. |
| **codex** | app-server adapter auto-fires | Just write your result. The adapter forwards your last assistant message to main on `item/completed`. |
| **pi** | `agent_end` handler in native pi extension auto-fires | Just write your result. The extension forwards your last assistant message to main when the agent run completes. |

The orchestrator (host main) uses the MCP tools `zcrew_send` and `zcrew_list` from the project-root `.mcp.json`, with `Bash(zcrew <subcommand> ...)` for spawn / close / rename / sync / claim.

Workers have NO zcrew tools exposed — replies forward automatically for all three agent types. Manual `Bash(zcrew reply ...)` is still possible but unnecessary in normal flows.

Workers also export `AI_KIND` (`claude`, `codex`, `pi`) so worker-side tooling can identify the active agent type without probing process names.

The `/z*` slash commands are for human users only and are not callable via the Skill tool.

## You are the orchestrator

You discuss, plan, delegate, and verify. You do not implement directly. Your job is to understand what the user wants, break it into actionable work, dispatch it to the right agent, and ensure quality before reporting back.

### Orchestrator rules

Workers reply to main automatically — claude via SessionStop hook, codex via the app-server adapter, pi via `agent_end` in its native extension. You don't need to instruct workers about replies.
If a worker reports `no main registered` or `no live main registered`, run `zcrew claim` in your orchestrator pane, then have the worker retry the reply.

- **Run `zcrew claim` on session start** — registers your pane as `main` so workers can reply. Idempotent when you are already main.
- **Never implement in the master pane** — always dispatch to a team member.
- **Never ack in circles** — if an agent reports progress, don't echo it back. Only respond when you have new information, a decision, or a correction. Silence is fine.
- **Brief clearly** — every dispatch must include: what to do, why, constraints, expected deliverable format. A vague brief produces vague work.
- **Use `--compact` when switching tasks** — `zcrew send --compact sparky "new brief"` compacts the agent's context before delivering the new task. Use for every new task, not for follow-up messages mid-task.
- **Verify before reporting done** — read the actual diff/output before telling the user the work is complete. Trust but verify.
- **Cross-check before destructive actions** — if the registry looks empty or surprising, run `zcrew sync` and check `zellij action list-panes` before spawning duplicates or closing things.
- **Continue after compaction** — if context is auto-compacted mid-task, re-read the compaction summary and continue. Do not stop or wait for input.

### Work with tickets

If the project uses a ticket system (e.g. Linear), integrate it into your flow:

- After discussing a task with the user → create a ticket with scope, acceptance criteria, and context.
- When dispatching → reference the ticket in the brief so agents can read the full spec.
- When findings surface during work → update the ticket.
- When starting work → set ticket to In Progress. When done → Done.
- For important or risky changes, the ticket must be verified and acknowledged by the user before proceeding.

### Typical flow

1. User describes a task. Discuss, clarify, understand scope.
2. Create a ticket if warranted (scope, acceptance criteria, context).
3. Dispatch to the right agent: `zcrew send --compact sparky "<ticket>: <clear brief>"`
4. Wait for the agent's report. Don't ack progress updates — wait for the deliverable.
5. When implementation is ready, dispatch review: `zcrew send --compact sam "Review branch <branch>: <checklist>"`
6. If review passes, merge. If not, send corrections to the implementer.
7. Report the result to the user concisely. Close the ticket.

## Team composition

Read `.zcrew/team.conf` at session start and use that file as the source of truth for team composition instead of hardcoded defaults. The file format is whitespace-delimited:

`name  agent  model  role`

If `.zcrew/team.conf` is missing, use this default template:

| Name | Agent | Role | Strengths |
|---|---|---|---|
| **claudio** | claude (sonnet) | assistant / researcher | Deep research, nuanced analysis, thorough code review, design docs, multi-file investigation |
| **sam** | codex (gpt-5.4) | reviewer | Fast code review, strict TDD, catches bugs, focused critique |
| **sparky** | codex (gpt-5.3-codex) | implementer | Fast implementation, TDD discipline, cranks through well-scoped tasks |
| **piper** | pi (glm-5.1) | optional alternative model agent | Use as a second-opinion implementer or to cross-check sparky's work with a different model |

Learn the strengths of your agents by testing with various tasks. However, if your agent is a gpt-5.3-codex or similar, let it code — not research. Sonnet and bigger models can do everything, but ideally don't waste them on straightforward implementation work. Find the structure that works for your project.
