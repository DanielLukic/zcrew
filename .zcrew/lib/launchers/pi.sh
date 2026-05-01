#!/bin/bash
# zcrew launcher: pi
#
# Pi inside bx needs:
#  (1) NPM_CONFIG_PREFIX — otherwise npm can infer a global prefix outside the
#      writable user tool tree and then fail when pi tries to install or
#      update widgets. Point it at $HOME/.local where pi's widgets live.
#  (2) PI_PACKAGE_DIR — pi's documented escape for read-only package stores
#      (designed for Nix/Guix). Points pi at its own install dir so it doesn't
#      try to mutate package state.
#  (3) sandbox-local ~/.pi/agent state — auth.json is copied by bx; mcp.json is
#      stubbed empty to block host MCP bleed.
set -euo pipefail

export NPM_CONFIG_PREFIX="$HOME/.local"
export PI_PACKAGE_DIR="$HOME/.local/lib/node_modules/@mariozechner/pi-coding-agent"

cmd=(pi --provider openai-codex --no-extensions --no-prompt-templates --no-themes --no-context-files --no-session)
if [[ -n "${ZCREW_MODEL:-}" ]]; then
  cmd+=(--model "$ZCREW_MODEL")
fi
exec bx run "${cmd[@]}"
