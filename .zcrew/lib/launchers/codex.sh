#!/bin/bash
# zcrew launcher: codex (bx-wrapped)
# -a never + -s danger-full-access: disable both approval prompts and codex's
# own sandbox. The sandbox disable is critical — codex's sandbox mounts a
# writable tmpfs over runtime dirs, which panics zellij with EROFS.
set -euo pipefail
project_dir="$PWD"
[[ -d "$project_dir/bin" ]] && export PATH="$project_dir/bin:$PATH"
cd "$project_dir"
exec bx run codex -a never -s danger-full-access ${ZCREW_MODEL:+--model "$ZCREW_MODEL"}
