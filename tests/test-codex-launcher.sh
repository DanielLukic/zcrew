#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
LAUNCHER="$ROOT/.zcrew/lib/launchers/codex.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
mkdir -p "$PROJECT/.zcrew/lib" "$PROJECT/.zcrew/state" "$PROJECT/mockbin"
cp "$LAUNCHER" "$PROJECT/launcher.sh"
chmod +x "$PROJECT/launcher.sh"

EVENTS="$TMP/events.log"
BX_ARGS="$TMP/bx-args.log"
cat > "$PROJECT/.zcrew/lib/codex-auto-reply.mjs" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';
const events = process.env.MOCK_EVENTS;
fs.appendFileSync(events, 'adapter-start\n');
if (process.env.BX_INSIDE !== '1') {
  fs.appendFileSync(events, `adapter-bx-missing:${process.env.BX_INSIDE || ''}\n`);
  process.exit(11);
}
setInterval(() => {}, 1000);
NODE
chmod +x "$PROJECT/.zcrew/lib/codex-auto-reply.mjs"

cat > "$PROJECT/mockbin/bx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${MOCK_BX_ARGS:?}"
: "${MOCK_OUTER_PID_FILE:?}"
# Outer launcher must have written outer.pid BEFORE invoking bx.
if [[ ! -f "$MOCK_OUTER_PID_FILE" ]]; then
  echo "outer.pid missing before bx re-entry" >&2
  exit 9
fi
if [[ "${1:-}" != "run" ]]; then
  exit 2
fi
shift
if [[ "${1:-}" == "--" ]]; then
  shift
fi
BX_INSIDE=1 "$@"
MOCK
chmod +x "$PROJECT/mockbin/bx"

cat > "$PROJECT/mockbin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
EVENTS="${MOCK_EVENTS:?}"
if [[ "${1:-}" == "app-server" ]]; then
  [[ "${BX_INSIDE:-}" == "1" ]] || exit 21
  echo "app-server-start" >> "$EVENTS"
  listen="$3"
  port="${listen##*:}"
  python3 - <<PY
import socket, time
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int("$port")))
s.listen(1)
try:
  time.sleep(60)
finally:
  s.close()
PY
  exit 0
fi
if [[ "${1:-}" == "--remote" ]]; then
  [[ "${BX_INSIDE:-}" == "1" ]] || exit 22
  sleep 0.1
  echo "tui-start" >> "$EVENTS"
  sleep 0.3
  exit 0
fi
exit 1
MOCK
chmod +x "$PROJECT/mockbin/codex"

export PATH="$PROJECT/mockbin:$PATH"
export MOCK_EVENTS="$EVENTS"
export MOCK_BX_ARGS="$BX_ARGS"
export MOCK_OUTER_PID_FILE="$PROJECT/.zcrew/state/codex-worker/44/outer.pid"
export ZELLIJ_PANE_ID="44"
export ZELLIJ_SESSION_NAME="sess"

(
  cd "$PROJECT"
  ./launcher.sh
)

state_dir="$PROJECT/.zcrew/state/codex-worker/44"
[[ -f "$state_dir/port" ]] || { echo "missing port file"; exit 1; }
[[ -f "$state_dir/outer.pid" ]] || { echo "missing outer.pid"; exit 1; }
outer_pid="$(cat "$state_dir/outer.pid")"
[[ "$outer_pid" =~ ^[0-9]+$ ]] || { echo "invalid outer.pid: $outer_pid"; exit 1; }

# Order: app-server -> adapter -> tui
actual="$(cat "$EVENTS")"
echo "$actual" | grep -q 'app-server-start' || { echo "missing app-server-start"; exit 1; }
echo "$actual" | grep -q 'adapter-start' || { echo "missing adapter-start"; exit 1; }
echo "$actual" | grep -q 'tui-start' || { echo "missing tui-start"; exit 1; }

order_ok="$(awk '
/app-server-start/{a=NR}
/adapter-start/{b=NR}
/tui-start/{c=NR}
END{if(a<b && b<c) print "yes"; else print "no"}
' "$EVENTS")"
[[ "$order_ok" == "yes" ]] || { echo "bad process order"; cat "$EVENTS"; exit 1; }
grep -Fq 'run -- bash ./launcher.sh --zcrew-inner-codex-launcher' "$BX_ARGS" || {
  echo "missing bx outer invocation"; cat "$BX_ARGS"; exit 1;
}

for f in app-server.pid auto-reply.pid; do
  if [[ -f "$state_dir/$f" ]]; then
    pid="$(cat "$state_dir/$f")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "orphaned pid $pid from $f"
      exit 1
    fi
  fi
done

echo "ok"
