#!/bin/bash
# zcrew-managed
# zcrew launcher: claude
# bx-wrapped claude in bypass-permissions mode. Safe because bx is the actual
# sandbox boundary — per-tool prompts just get in the way inside it.
#
# Pre-seed the sandbox's ~/.claude/settings.json with
# skipDangerousModePermissionPrompt so the first spawn doesn't hit the one-time
# "are you sure?" dialog. The key is top-level (not under "permissions").
set -euo pipefail
export AI_KIND=claude
project_dir="$PWD"
launcher_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$(dirname "$launcher_dir")"
[[ -d "$project_dir/bin" ]] && export PATH="$project_dir/bin:$PATH"
cd "$project_dir"
if [[ -d .bx/home ]] && [[ ! -f .bx/home/.claude/settings.json ]]; then
  mkdir -p .bx/home/.claude
  printf '{"skipDangerousModePermissionPrompt":true}\n' > .bx/home/.claude/settings.json
fi
# Idempotent merge of the SessionStop auto-reply hook into project-local
# .claude/settings.local.json. Project-local (not sandbox-home) because bx's
# seed_claude_sandbox_state overwrites .bx/home/.claude/settings.json on every
# spawn, which would wipe a hook registered there.
if command -v jq >/dev/null 2>&1; then
  settings_local="$project_dir/.claude/settings.local.json"
  mkdir -p "$(dirname "$settings_local")"
  [[ -f "$settings_local" ]] || printf '{}\n' > "$settings_local"
  stop_hook_cmd="$lib_dir/stop-hook.sh"
  settings_tmp="$settings_local.tmp.$$"
  if jq --arg cmd "$stop_hook_cmd" '
    .hooks = (.hooks // {})
    | .hooks.Stop = (.hooks.Stop // [])
    | if ([.hooks.Stop[]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length) > 0
      then . else .hooks.Stop += [{matcher:"*", hooks:[{type:"command", command:$cmd}]}] end
  ' "$settings_local" > "$settings_tmp" 2>/dev/null; then
    mv "$settings_tmp" "$settings_local"
  else
    rm -f "$settings_tmp"
  fi
fi

cmd=(claude --dangerously-skip-permissions --model "${ZCREW_MODEL:-sonnet}" --setting-sources project,local --strict-mcp-config)
exec bx run "${cmd[@]}"
