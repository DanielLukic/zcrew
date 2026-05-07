#!/usr/bin/env bash
# zcrew stop-hook (simplified)
# Claude SessionStop hook: auto-fires `zcrew reply <assistant_text>` when the
# last assistant message contains text. No DONE marker parsing.
set -uo pipefail

hook_input="$(cat 2>/dev/null || true)"

[[ -n "${BX_INSIDE:-}" ]] || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$project_dir" || ! -d "$project_dir/.zcrew" ]]; then
  dir="$PWD"
  while true; do
    if [[ -d "$dir/.zcrew" ]]; then
      project_dir="$dir"
      break
    fi
    [[ "$dir" != "/" ]] || break
    dir="$(dirname "$dir")"
  done
fi
[[ -n "$project_dir" && -d "$project_dir/.zcrew" ]] || exit 0

zcrew_bin="${ZCREW_BIN:-}"
if [[ -z "$zcrew_bin" || ! -x "$zcrew_bin" ]]; then
  self="${BASH_SOURCE[0]}"
  real_self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
  zcrew_bin="$(cd "$(dirname "$real_self")" && pwd)/../bin/zcrew"
fi
[[ -x "$zcrew_bin" ]] || exit 0

assistant_text="$(jq -r '.last_assistant_message // empty' <<<"$hook_input" 2>/dev/null || true)"

if [[ -z "$assistant_text" ]]; then
  session_id="$(jq -r '.session_id // .sessionId // empty' <<<"$hook_input" 2>/dev/null || true)"
  [[ -n "$session_id" ]] || exit 0

  transcript="$(jq -r '.transcript_path // empty' <<<"$hook_input" 2>/dev/null || true)"
  if [[ -z "$transcript" ]]; then
    sanitized_cwd="${project_dir//\//-}"
    transcript="$HOME/.claude/projects/$sanitized_cwd/$session_id.jsonl"
  fi
  [[ -r "$transcript" ]] || exit 0

  assistant_text="$(jq -Rrsc '
    split("\n")
    | map(select(length > 0) | (try fromjson catch empty))
    | map(select(.type == "assistant"))
    | map(select(any(.message.content[]?; .type == "text" and (.text | type == "string"))))
    | last
    | .message.content // []
    | map(select(.type == "text" and (.text | type == "string")) | .text)
    | join("\n")
  ' "$transcript" 2>/dev/null || true)"
fi

[[ -n "$assistant_text" ]] || exit 0
"$zcrew_bin" reply "$assistant_text" >/dev/null 2>&1 || true
exit 0
