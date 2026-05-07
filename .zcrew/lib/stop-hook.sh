#!/usr/bin/env bash
# zcrew stop-hook
# Claude SessionStop hook: auto-fires `zcrew reply <payload>` when the last
# assistant message ends with `<<DONE: payload>>`.
#
# Stripped port of develop's lib/zcrew/claude/stop-hook.sh. Differences:
# - No outbox/feed call → uses `zcrew reply "$payload"` (our existing CLI).
# - No target= variant → only `<<DONE: payload>>` (always targets main).
# - No ZCREW_ME / current.json sender resolution (we always reply to main).
#
# Fail-closed: every parse/lookup/transcript failure exits 0. The hook must
# NEVER block claude exit.
set -uo pipefail

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

hook_input="$(cat 2>/dev/null || true)"
session_id="$(jq -r '.session_id // .sessionId // empty' <<<"$hook_input" 2>/dev/null || true)"
[[ -n "$session_id" ]] || exit 0

sanitized_cwd="${project_dir//\//-}"
transcript="$HOME/.claude/projects/$sanitized_cwd/$session_id.jsonl"
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
[[ -n "$assistant_text" ]] || exit 0

payload="$(printf '%s' "$assistant_text" | perl -0777 -e '
  use strict;
  use warnings;

  my $text = do { local $/; <STDIN> };
  my $trim = $text;
  $trim =~ s/\s+\z//s;
  exit 0 if $trim eq q{};

  my $line_start = rindex($trim, "\n");
  $line_start = ($line_start < 0) ? 0 : ($line_start + 1);
  my $line_end = length($trim);

  my @last;
  while ($text =~ /<<DONE:\s*(.*?)>>/gs) {
    @last = ($1, $-[0], $+[0]);
  }
  exit 0 unless @last;

  my ($payload, $start, $end) = @last;
  exit 0 if $end <= $line_start || $start >= $line_end;

  print $payload;
' 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0

"$zcrew_bin" reply "$payload" >/dev/null 2>&1 || true
exit 0
