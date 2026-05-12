#!/usr/bin/env bash
# zcrew stop-hook (simplified)
# Claude SessionStop hook: auto-fires `zcrew reply <assistant_text>` when the
# last assistant message contains text. No DONE marker parsing.
set -uo pipefail

hook_input="$(cat 2>/dev/null || true)"

[[ -n "${BX_INSIDE:-}" ]] || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir=""
if [[ "$script_dir" == */.zcrew/lib ]]; then
  project_dir="${script_dir%/.zcrew/lib}"
fi
if [[ -z "$project_dir" || ! -d "$project_dir/.zcrew" ]]; then
  project_dir="${CLAUDE_PROJECT_DIR:-}"
fi
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
resolve_zcrew_bin() {
  local override="${ZCREW_BIN:-}"
  local self real_self sibling found
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || return 1
    printf '%s\n' "$(realpath "$override")"
    return 0
  fi
  self="${BASH_SOURCE[0]}"
  real_self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
  sibling="$(cd "$(dirname "$real_self")" && pwd)/../bin/zcrew"
  if [[ -x "$sibling" ]]; then
    printf '%s\n' "$(realpath "$sibling")"
    return 0
  fi
  found="$(command -v zcrew 2>/dev/null || true)"
  if [[ -n "$found" && -x "$found" ]]; then
    printf '%s\n' "$(realpath "$found")"
    return 0
  fi
  return 1
}

zcrew_bin="$(resolve_zcrew_bin)" || {
  echo "zcrew stop-hook: zcrew binary not found (checked ZCREW_BIN, local ../bin/zcrew, and PATH)" >&2
  exit 1
}

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
cd "$project_dir" || exit 0

zcrew_err=""
zcrew_rc=0
zcrew_err="$("$zcrew_bin" reply "$assistant_text" 2>&1 >/dev/null)" || zcrew_rc=$?

if [[ $zcrew_rc -eq 0 ]]; then
  exit 0
fi

# Sanitize stderr for embedding in JSON reason
sanitized="${zcrew_err//[^[:print:][:space:]]/}"
sanitized="$(printf '%s' "$sanitized" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ ${#sanitized} -gt 500 ]] && sanitized="${sanitized:0:497}..."

stop_hook_active="$(jq -r '.stop_hook_active // false' <<<"$hook_input" 2>/dev/null || true)"
if [[ "$stop_hook_active" == "true" ]]; then
  printf 'zcrew stop-hook: still failing after retry — giving up to prevent loop: %s\n' "$sanitized" >&2
  exit 0
fi

reason="ADAPTER ERROR: zcrew failed to deliver this turn's reply (${sanitized:-unknown}). Please attempt to inform the user, retry the action that requires the reply, or escalate."
printf 'zcrew stop-hook: reply failed, asking claude to handle: %s\n' "$sanitized" >&2
"$zcrew_bin" log-error claude "zcrew reply failed: ${sanitized:-unknown}" >/dev/null 2>&1 || true

decision_json="$(jq -nc --arg reason "$reason" '{decision:"block", reason:$reason}' 2>/dev/null)" || true
if [[ -z "$decision_json" ]]; then
  printf 'zcrew stop-hook: failed to construct decision JSON (jq missing or broken)\n' >&2
  exit 1
fi
printf '%s\n' "$decision_json"
exit 0
