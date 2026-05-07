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

# ── resolve project dir ──────────────────────────────────────────────
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$project_dir" || ! -d "$project_dir/.zcrew" ]]; then
  # Fall back: walk upward from CWD
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

# ── resolve zcrew binary ─────────────────────────────────────────────
zcrew_bin="${ZCREW_BIN:-}"
if [[ -z "$zcrew_bin" || ! -x "$zcrew_bin" ]]; then
  # Resolve relative to script dir: ../bin/zcrew
  self="${BASH_SOURCE[0]}"
  real_self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
  zcrew_bin="$(cd "$(dirname "$real_self")" && pwd)/../bin/zcrew"
fi
[[ -x "$zcrew_bin" ]] || exit 0

# ── read hook input (stdin JSON: {"session_id":"..."}) ──────────────
hook_input="$(cat 2>/dev/null || true)"
session_id="$(jq -r '.session_id // .sessionId // empty' <<<"$hook_input" 2>/dev/null || true)"
[[ -n "$session_id" ]] || exit 0

# ── locate transcript ────────────────────────────────────────────────
sanitized_cwd="${project_dir//\//-}"
transcript="$HOME/.claude/projects/$sanitized_cwd/$session_id.jsonl"
[[ -r "$transcript" ]] || exit 0

# ── extract last assistant text ──────────────────────────────────────
# Claude Code writes each content block as its own JSONL line.
# Slurp all lines, filter to assistant role, take the last, extract text blocks.
assistant_text="$(jq -Rrsc '
  split("\n")
  | map(select(length > 0) | (try fromjson catch empty))
  | map(select(.type == "assistant"))
  | last
  | .message.content // []
  | map(select(.type == "text" and (.text | type == "string")) | .text)
  | join("\n")
' "$transcript" 2>/dev/null || true)"
[[ -n "$assistant_text" ]] || exit 0

# ── LAST-line perl check (verbatim from develop) ────────────────────
# Uses perl to:
#   1. Trim trailing whitespace from the full assistant text.
#   2. Find the range of the final line.
#   3. Find all <<DONE: ...>> markers, keep the last one.
#   4. Verify the last marker's span overlaps with the final line range.
#   5. Print the payload to stdout (exit 0), or exit 0 silently.
#
# No target= capture (removed from develop's variant).
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

# ── fire zcrew reply ─────────────────────────────────────────────────
"$zcrew_bin" reply "$payload" >/dev/null 2>&1 || true
exit 0
