#!/bin/bash
# zcrew launcher: claude
# bx-wrapped claude in bypass-permissions mode. Safe because bx is the actual
# sandbox boundary — per-tool prompts just get in the way inside it.
#
# Pre-seed the sandbox's ~/.claude/settings.json with
# skipDangerousModePermissionPrompt so the first spawn doesn't hit the one-time
# "are you sure?" dialog. The key is top-level (not under "permissions").
set -euo pipefail
project_dir="$PWD"
[[ -d "$project_dir/bin" ]] && export PATH="$project_dir/bin:$PATH"
cd "$project_dir"
if [[ -d .bx/home ]] && [[ ! -f .bx/home/.claude/settings.json ]]; then
  mkdir -p .bx/home/.claude
  printf '{"skipDangerousModePermissionPrompt":true}\n' > .bx/home/.claude/settings.json
fi
cmd=(claude --dangerously-skip-permissions --model "${ZCREW_MODEL:-sonnet}" --setting-sources project,local --strict-mcp-config)
exec bx run "${cmd[@]}"
