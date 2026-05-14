# zcrew-managed

_mx_ensure_init() {
  if [[ -n "${_MX_BACKEND:-}" ]]; then
    return 0
  fi
  if [[ -n "${ZELLIJ_SESSION_NAME:-}" && -n "${TMUX:-}" ]]; then
    echo "zcrew: ZELLIJ_SESSION_NAME and TMUX are both set; nested session unsupported" >&2
    exit 1
  fi
  if [[ -n "${ZELLIJ_SESSION_NAME:-}" ]]; then
    _MX_BACKEND="zellij"
  elif [[ -n "${TMUX:-}" ]]; then
    _MX_BACKEND="tmux"
  fi
}

# ONLY called from _mx_require_backend — do NOT wire to non-mux paths.
check_and_migrate_backend() {
  local stored_backend=""
  [[ -n "${REGISTRY_FILE:-}" ]] || return 0
  [[ -f "$REGISTRY_FILE" ]] || return 0

  stored_backend="$(jq -r '.backend // empty' "$REGISTRY_FILE")"
  if [[ -z "$stored_backend" ]]; then
    registry_write_jq '.backend = $backend' --arg backend "$_MX_BACKEND"
    return 0
  fi
  if [[ "$stored_backend" == "$_MX_BACKEND" ]]; then
    return 0
  fi

  registry_write_jq '.panes = {} | .backend = $backend' --arg backend "$_MX_BACKEND"
  logger "backend-reset" "warn" "from=$stored_backend to=$_MX_BACKEND reason=mux-switch"
  echo "zcrew: multiplexer changed ($stored_backend → $_MX_BACKEND); registry reset. Old workers are orphaned." >&2
}

_mx_require_backend() {
  _mx_ensure_init
  if [[ -z "${_MX_BACKEND:-}" ]]; then
    echo "zcrew: this command requires a multiplexer session; ZELLIJ_SESSION_NAME and TMUX are both unset" >&2
    exit 1
  fi
  if [[ -z "${_MX_BACKEND_CHECKED:-}" ]]; then
    check_and_migrate_backend
    _MX_BACKEND_CHECKED=1
  fi
}

mx_pane_id() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij)
      printf '%s\n' "${ZELLIJ_PANE_ID:-}"
      [[ -n "${ZELLIJ_PANE_ID:-}" ]]
      ;;
    tmux)
      local pane_id="${TMUX_PANE:-}"
      pane_id="${pane_id#%}"
      printf '%s\n' "$pane_id"
      [[ -n "$pane_id" ]]
      ;;
  esac
}

mx_session_name() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij)
      printf '%s\n' "${ZELLIJ_SESSION_NAME:-}"
      [[ -n "${ZELLIJ_SESSION_NAME:-}" ]]
      ;;
    tmux)
      local session_name=""
      session_name="$(tmux display-message -p '#S' 2>/dev/null)" || return 1
      [[ -n "$session_name" ]] || return 1
      printf '%s\n' "$session_name"
      ;;
  esac
}

mx_require_session() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij)
      if ! zellij list-sessions -s 2>/dev/null | grep -qFx "${ZELLIJ_SESSION_NAME:-}"; then
        echo "zcrew: ZELLIJ_SESSION_NAME='${ZELLIJ_SESSION_NAME:-}' is stale (session renamed or gone)." >&2
        exit 1
      fi
      ;;
    tmux)
      local session_name=""
      if [[ -z "${TMUX:-}" ]]; then
        echo "zcrew: TMUX is unset; run this command inside a live tmux session." >&2
        exit 1
      fi
      session_name="$(mx_session_name)" || {
        echo "zcrew: could not determine tmux session name; run this command inside a live tmux session." >&2
        exit 1
      }
      if ! tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qFx "$session_name"; then
        echo "zcrew: TMUX session '$session_name' is stale (session renamed or gone)." >&2
        exit 1
      fi
      ;;
  esac
}

mx_new_pane() {
  _mx_require_backend
  local cwd="$1"
  local name="$2"
  local cmd="$3"
  local out=""
  local pane_id=""
  case "$_MX_BACKEND" in
    zellij)
      out="$(zellij action new-pane --cwd "$cwd" --name "$name" -- bash -c "$cmd")" || return 1
      pane_id="$(printf '%s\n' "$out" | grep -m1 '^terminal_' | sed 's/^terminal_//')"
      if [[ -z "$pane_id" ]]; then
        # Some tests source this library standalone, outside the main binary.
        if declare -F logger >/dev/null 2>&1; then
          logger "spawn" "warn" "could not parse pane id from new-pane output: $out"
        fi
        printf '?\n'
      else
        printf '%s\n' "$pane_id"
      fi
      ;;
    tmux)
      out="$(tmux split-window -d -P -F '#{pane_id}' -c "$cwd" -t "$TMUX_PANE" -- bash -c "$cmd")" || return 1
      pane_id="${out#%}"
      if [[ ! "$pane_id" =~ ^[0-9]+$ ]]; then
        # Some tests source this library standalone, outside the main binary.
        if declare -F logger >/dev/null 2>&1; then
          logger "spawn" "warn" "could not parse pane id from split-window output: $out"
        fi
        printf '?\n'
      else
        if [[ -z "${_MX_TMUX_BORDER_WARNED:-}" ]]; then
          local border_status=""
          border_status="$(tmux show-options -gv pane-border-status 2>/dev/null || true)"
          if [[ -z "$border_status" || "$border_status" == "off" ]]; then
            echo "zcrew: tmux pane titles are hidden; set 'set -g pane-border-status top' in .tmux.conf to see worker names." >&2
          fi
          _MX_TMUX_BORDER_WARNED=1
        fi
        tmux select-pane -t "%$pane_id" -T "$name" 2>/dev/null || true
        tmux set-option -p -t "%$pane_id" @zcrew-name "$name" 2>/dev/null || true
        tmux select-layout tiled 2>/dev/null || true
        printf '%s\n' "$pane_id"
      fi
      ;;
  esac
}

mx_close_pane() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij) zellij action close-pane -p "$1" 2>/dev/null || true ;;
    tmux) tmux kill-pane -t "%$1" 2>/dev/null || true ;;
  esac
}

mx_rename_pane() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij) zellij action rename-pane -p "$1" "$2" 2>/dev/null || true ;;
    tmux)
      tmux select-pane -t "%$1" -T "$2" 2>/dev/null || true
      tmux set-option -p -t "%$1" @zcrew-name "$2" 2>/dev/null || true
      ;;
  esac
}

mx_list_pane_ids() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij) zellij action list-panes 2>/dev/null | sed -n 's/.*terminal_\([0-9][0-9]*\).*/\1/p' ;;
    tmux)
      local session_name=""
      session_name="$(mx_session_name 2>/dev/null)" || return 0
      tmux list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null |
        awk -v s="$session_name" '$2==s {sub(/^%/, "", $1); print $1}'
      ;;
  esac
}

# mx_list_panes returns one line per live terminal pane:
#   pane_id<TAB>name
# Pane IDs have prefixes stripped (no terminal_ / no %).
# For tmux, "name" is the @zcrew-name custom pane option (TUI-proof); panes
# without @zcrew-name set produce an empty name (treated as unregistered).
# Names are sanitized: tabs collapsed to single space.
mx_list_panes() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij)
      zellij action list-panes 2>/dev/null |
        awk 'NR==1 {next} $2=="terminal" {
          sub(/^terminal_/, "", $1)
          # Reconstruct title from field 3 onward (may contain spaces)
          title = $3
          for (i=4; i<=NF; i++) title = title " " $i
          gsub(/\t/, " ", title)
          print $1 "\t" title
        }'
      ;;
    tmux)
      local session_name=""
      session_name="$(mx_session_name 2>/dev/null)" || return 0
      tmux list-panes -a -F $'#{pane_id}\x01#{@zcrew-name}\x01#{session_name}' 2>/dev/null |
        awk -F $'\x01' -v s="$session_name" '$3==s {
          sub(/^%/, "", $1)
          gsub(/\t/, " ", $2)
          print $1 "\t" $2
        }'
      ;;
  esac
}

mx_send_text() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij)
      zellij action write 27 91 50 48 48 126 --pane-id "$1"
      zellij action write-chars "$2" --pane-id "$1"
      zellij action write 27 91 50 48 49 126 --pane-id "$1"
      sleep 0.15
      zellij action write 13 --pane-id "$1"
      ;;
    tmux)
      tmux send-keys -t "%$1" -l -- "$(printf '\033[200~%s\033[201~' "$2")"
      sleep 0.15
      tmux send-keys -t "%$1" -l -- $'\r'
      ;;
  esac
}

mx_socket_dir() {
  _mx_require_backend
  case "$_MX_BACKEND" in
    zellij) echo "/run/user/$(id -u)/zellij" ;;
    tmux)
      if [[ -z "${TMUX:-}" ]]; then
        echo "zcrew: tmux backend selected but \$TMUX is empty (no live session?); cannot determine socket dir" >&2
        exit 1
      fi
      local sock_path=""
      IFS=',' read -r sock_path _ _ <<< "$TMUX"
      dirname "$sock_path"
      ;;
  esac
}
