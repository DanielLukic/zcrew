#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_GLOBALS="$REPO_ROOT/install-globals.sh"
TMP_BASE="$REPO_ROOT/.tmp"
TEST_ROOT="$TMP_BASE/install-globals-tests"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

new_test_dir() {
  local n="$1"
  local d="$TEST_ROOT/install-globals-test-$n"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

run_install_globals() {
  local home_dir="$1"
  shift
  (
    cd "$REPO_ROOT" || exit 1
    HOME="$home_dir" ./install-globals.sh "$@"
  )
}

make_mock_systemctl() {
  local bindir="$1"
  local args_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_SYSTEMCTL_ARGS_FILE:?MOCK_SYSTEMCTL_ARGS_FILE is required}"
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_ARGS_FILE"
exit 0
MOCK
  chmod +x "$bindir/systemctl"
}

run_install_globals_env() {
  local home_dir="$1"
  shift

  local env_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    env_args+=("$1")
    shift
  done

  (
    cd "$REPO_ROOT" || exit 1
    env HOME="$home_dir" "${env_args[@]}" ./install-globals.sh "$@"
  )
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1"
}

run_test() {
  local name="$1"
  local fn="$2"
  if "$fn"; then
    pass "$name"
  else
    fail "$name"
  fi
}

test_1_include_zcrew_copies_codex_skill() {
  local d home_dir mockbin args_file
  d="$(new_test_dir 1)"
  home_dir="$d/home"
  mockbin="$d/mock-bin"
  args_file="$d/systemctl-args.txt"
  mkdir -p "$home_dir"
  make_mock_systemctl "$mockbin" "$args_file"

  run_install_globals_env "$home_dir" "PATH=$mockbin:$PATH" "MOCK_SYSTEMCTL_ARGS_FILE=$args_file" -- --include-zcrew >/dev/null 2>&1 || return 1

  [[ -f "$home_dir/.codex/skills/zcrew/SKILL.md" ]] || return 1
  cmp -s "$REPO_ROOT/.codex/skills/zcrew/SKILL.md" "$home_dir/.codex/skills/zcrew/SKILL.md"
}

test_2_include_zcrew_copies_pi_skills() {
  local d home_dir skill mockbin args_file
  d="$(new_test_dir 2)"
  home_dir="$d/home"
  mockbin="$d/mock-bin"
  args_file="$d/systemctl-args.txt"
  mkdir -p "$home_dir"
  make_mock_systemctl "$mockbin" "$args_file"

  run_install_globals_env "$home_dir" "PATH=$mockbin:$PATH" "MOCK_SYSTEMCTL_ARGS_FILE=$args_file" -- --include-zcrew >/dev/null 2>&1 || return 1

  for skill in zcrew zspawn zsend zpanes zsync zname zclose; do
    [[ -f "$home_dir/.pi/agent/skills/$skill/SKILL.md" ]] || return 1
    cmp -s "$REPO_ROOT/.pi/skills/$skill/SKILL.md" "$home_dir/.pi/agent/skills/$skill/SKILL.md" || return 1
  done
}

test_3_without_flag_does_not_deploy_skills() {
  local d home_dir mockbin args_file
  d="$(new_test_dir 3)"
  home_dir="$d/home"
  mockbin="$d/mock-bin"
  args_file="$d/systemctl-args.txt"
  mkdir -p "$home_dir"
  make_mock_systemctl "$mockbin" "$args_file"

  run_install_globals_env "$home_dir" "PATH=$mockbin:$PATH" "MOCK_SYSTEMCTL_ARGS_FILE=$args_file" -- >/dev/null 2>&1 || return 1

  [[ -f "$home_dir/.local/bin/bx" ]] || return 1
  [[ -f "$home_dir/.local/bin/ix" ]] || return 1
  [[ -f "$home_dir/.local/bin/claude-auth-sync" ]] || return 1
  [[ ! -e "$home_dir/.codex/skills/zcrew" ]] || return 1
  [[ ! -e "$home_dir/.pi/agent/skills" ]]
}

test_4_dry_run_include_zcrew_prints_but_does_not_copy() {
  local d home_dir out
  d="$(new_test_dir 4)"
  home_dir="$d/home"
  mkdir -p "$home_dir"

  out="$(run_install_globals "$home_dir" --dry-run --include-zcrew 2>&1)" || return 1

  printf '%s\n' "$out" | grep -Fq "would install $REPO_ROOT/bin/bx to $home_dir/.local/bin/bx" || return 1
  printf '%s\n' "$out" | grep -Fq "would sync $REPO_ROOT/.codex/skills/zcrew/ to $home_dir/.codex/skills/zcrew/" || return 1
  printf '%s\n' "$out" | grep -Fq "would sync $REPO_ROOT/.pi/skills/zspawn/ to $home_dir/.pi/agent/skills/zspawn/" || return 1
  [[ ! -e "$home_dir/.local/bin/bx" ]] || return 1
  [[ ! -e "$home_dir/.codex/skills/zcrew" ]] || return 1
  [[ ! -e "$home_dir/.pi/agent/skills" ]]
}

test_5_install_copies_claude_auth_sync_and_systemd_units() {
  local d home_dir mockbin args_file
  d="$(new_test_dir 5)"
  home_dir="$d/home"
  mockbin="$d/mock-bin"
  args_file="$d/systemctl-args.txt"
  mkdir -p "$home_dir"
  make_mock_systemctl "$mockbin" "$args_file"

  run_install_globals_env "$home_dir" "PATH=$mockbin:$PATH" "MOCK_SYSTEMCTL_ARGS_FILE=$args_file" -- >/dev/null 2>&1 || return 1

  [[ -f "$home_dir/.local/bin/claude-auth-sync" ]] || return 1
  [[ -x "$home_dir/.local/bin/claude-auth-sync" ]] || return 1
  cmp -s "$REPO_ROOT/bin/claude-auth-sync" "$home_dir/.local/bin/claude-auth-sync" || return 1
  [[ -f "$home_dir/.config/systemd/user/claude-auth-sync.service" ]] || return 1
  [[ -f "$home_dir/.config/systemd/user/claude-auth-sync.path" ]] || return 1
  cmp -s "$REPO_ROOT/lib/ix/systemd/claude-auth-sync.service" "$home_dir/.config/systemd/user/claude-auth-sync.service" || return 1
  cmp -s "$REPO_ROOT/lib/ix/systemd/claude-auth-sync.path" "$home_dir/.config/systemd/user/claude-auth-sync.path" || return 1
  grep -Fxq -- '--user daemon-reload' "$args_file"
}

test_6_dry_run_prints_claude_auth_sync_and_systemd_actions_without_copying() {
  local d home_dir out
  d="$(new_test_dir 6)"
  home_dir="$d/home"
  mkdir -p "$home_dir"

  out="$(run_install_globals "$home_dir" --dry-run 2>&1)" || return 1

  printf '%s\n' "$out" | grep -Fq "would install $REPO_ROOT/bin/claude-auth-sync to $home_dir/.local/bin/claude-auth-sync" || return 1
  printf '%s\n' "$out" | grep -Fq "would install $REPO_ROOT/lib/ix/systemd/claude-auth-sync.service to $home_dir/.config/systemd/user/claude-auth-sync.service" || return 1
  printf '%s\n' "$out" | grep -Fq "would run systemctl --user daemon-reload" || return 1
  [[ ! -e "$home_dir/.local/bin/claude-auth-sync" ]] || return 1
  [[ ! -e "$home_dir/.config/systemd/user/claude-auth-sync.service" ]]
}

main() {
  run_test "1) --include-zcrew copies codex skill to ~/.codex/skills/zcrew" test_1_include_zcrew_copies_codex_skill
  run_test "2) --include-zcrew copies pi skills to ~/.pi/agent/skills" test_2_include_zcrew_copies_pi_skills
  run_test "3) without flag only installs bx and ix" test_3_without_flag_does_not_deploy_skills
  run_test "4) --dry-run --include-zcrew prints actions without copying" test_4_dry_run_include_zcrew_prints_but_does_not_copy
  run_test "5) install copies claude-auth-sync and systemd units" test_5_install_copies_claude_auth_sync_and_systemd_units
  run_test "6) dry-run prints claude-auth-sync and systemd actions without copying" test_6_dry_run_prints_claude_auth_sync_and_systemd_actions_without_copying

  echo ""
  echo "Total: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
