
#!/usr/bin/env bash
# zcrew-managed
# codex launcher with app-server sidecar + auto-reply adapter while keeping TUI visible.
set -euo pipefail
export AI_KIND=codex

project_dir="$PWD"
[[ -d "$project_dir/bin" ]] && export PATH="$project_dir/bin:$PATH"
cd "$project_dir"

pane_id="${ZELLIJ_PANE_ID:-$$}"
state_dir="$project_dir/.zcrew/state/codex-worker/$pane_id"

# Keep all codex worker processes inside bx. Outer launcher re-enters itself
# under bx; inner launcher orchestrates app-server + adapter + TUI.
if [[ "${1:-}" != "--zcrew-inner-codex-launcher" ]]; then
  mkdir -p "$state_dir"
  # Host-visible PID for killing the entire bwrap namespace from outside.
  printf '%s\n' "$$" > "$state_dir/outer.pid"
  exec bx run -- bash "$0" --zcrew-inner-codex-launcher
fi

# Re-assert inside the inner launcher path as an explicit invariant.
export AI_KIND=codex

session_name="${ZELLIJ_SESSION_NAME:-default}"
mkdir -p "$state_dir"

app_pid_file="$state_dir/app-server.pid"
adapter_pid_file="$state_dir/auto-reply.pid"
port_file="$state_dir/port"
app_log="$state_dir/app-server.log"
adapter_log="$state_dir/auto-reply.log"

reap_stale_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(tr -dc '0-9' < "$file" || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$file"
}

kill_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(tr -dc '0-9' < "$file" || true)"
  [[ -n "$pid" ]] || { rm -f "$file"; return 0; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$file"
}

port_is_open() {
  local port="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
  else
    (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
  fi
}

port_in_use() {
  port_is_open "$1"
}

wait_for_port() {
  local port="$1"
  local deadline=$((SECONDS + 5))
  until port_is_open "$port"; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

cleanup() {
  kill_pid_file "$adapter_pid_file"
  kill_pid_file "$app_pid_file"
}
trap cleanup EXIT INT TERM

reap_stale_pid_file "$app_pid_file"
reap_stale_pid_file "$adapter_pid_file"

hash_input="$session_name:$pane_id"
hash_num="$(printf '%s' "$hash_input" | cksum | awk '{print $1}')"
port=$((49152 + (hash_num % 16384)))

for _ in $(seq 1 16384); do
  if ! port_in_use "$port"; then
    break
  fi
  port=$((port + 1))
  if (( port > 65535 )); then
    port=49152
  fi
done

if port_in_use "$port"; then
  echo "[codex-launcher] failed to find free port in 49152-65535" >&2
  exit 1
fi

printf '%s\n' "$port" > "$port_file"
ws_url="ws://127.0.0.1:$port"

codex app-server --listen "$ws_url" >>"$app_log" 2>&1 &
app_pid=$!
printf '%s\n' "$app_pid" > "$app_pid_file"

if ! wait_for_port "$port"; then
  echo "[codex-launcher] app-server not ready on $ws_url within 5s" >&2
  exit 1
fi

ZCREW_CODEX_WS_URL="$ws_url" \
ZCREW_CODEX_STATE_DIR="$state_dir" \
  node "$project_dir/.zcrew/lib/codex-auto-reply.mjs" >>"$adapter_log" 2>&1 &
adapter_pid=$!
printf '%s\n' "$adapter_pid" > "$adapter_pid_file"

codex --remote "$ws_url" --no-alt-screen -a never -s danger-full-access --model "${ZCREW_MODEL:-gpt-5.4}"
tui_rc=$?

exit "$tui_rc"
