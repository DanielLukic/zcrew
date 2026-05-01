#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BX_BIN="$REPO_ROOT/.zcrew/bin/bx"
TMP_ROOT="$REPO_ROOT/.tmp"
BASE_PROJECT_ROOT="$TMP_ROOT/test"
HOST_HOME="$TMP_ROOT/host-home"
HOST_LOCAL_AVAILABLE=1

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

prepare_host_home() {
    rm -rf "$HOST_HOME"
    mkdir -p "$HOST_HOME/.claude" "$HOST_HOME/.codex" "$HOST_HOME/.pi/agent"
    printf '{"dummy":true}\n' > "$HOST_HOME/.claude.json"
    printf '{"dummy":true}\n' > "$HOST_HOME/.claude/.credentials.json"
    printf '{"dummy":true}\n' > "$HOST_HOME/.codex/auth.json"
    printf 'model = "dummy"\n' > "$HOST_HOME/.codex/config.toml"
    printf '{"providers":{"openai-codex":{"token":"dummy"}}}\n' > "$HOST_HOME/.pi/agent/auth.json"
    printf '{"mcpServers":{"host":{}}}\n' > "$HOST_HOME/.pi/agent/mcp.json"
    printf '{"defaultProvider":"host","defaultModel":"host-model"}\n' > "$HOST_HOME/.pi/agent/settings.json"
    printf '{"providers":{"custom":{}}}\n' > "$HOST_HOME/.pi/agent/models.json"
    if [[ ! -d "$HOME/.local" ]]; then
        echo "skip: $HOME/.local not present"
        HOST_LOCAL_AVAILABLE=0
        return 0
    fi
    ln -s "$HOME/.local" "$HOST_HOME/.local"
    mkdir -p "$HOST_HOME/.config"
    ln -s "$HOME/.config/mise" "$HOST_HOME/.config/mise"
}

new_project_dir() {
    local name="$1"
    local project_dir="$BASE_PROJECT_ROOT/$name"
    rm -rf "$project_dir"
    mkdir -p "$project_dir"
    printf '%s\n' "$project_dir"
}

bx_cmd() {
    local project_dir="$1"
    shift
    (
        cd "$project_dir" || exit 1
        env -u BX_INSIDE HOME="$HOST_HOME" TERM="${TERM:-xterm-256color}" "$BX_BIN" "$@"
    )
}

bx_cmd_env() {
    local project_dir="$1"
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
        cd "$project_dir" || exit 1
        env -u BX_INSIDE "${env_args[@]}" HOME="$HOST_HOME" TERM="${TERM:-xterm-256color}" "$BX_BIN" "$@"
    )
}

make_mock_bwrap() {
    local bindir="$1"
    local args_file="$2"
    mkdir -p "$bindir"
    cat > "$bindir/bwrap" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_BWRAP_ARGS_FILE:?MOCK_BWRAP_ARGS_FILE is required}"
printf '%s\n' "$@" > "$MOCK_BWRAP_ARGS_FILE"
exit 0
MOCK
    chmod +x "$bindir/bwrap"
}

pass() {
    local msg="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $msg"
}

fail() {
    local msg="$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $msg"
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

test_1_init_defaults() {
    local p
    p="$(new_project_dir test1)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1

    grep -q '^CLAUDE=on$' "$p/.bx/config" || return 1
    grep -q '^CODEX=on$' "$p/.bx/config" || return 1
}

test_2_claude_toggle() {
    local p
    p="$(new_project_dir test2)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" claude off >/dev/null 2>&1 || return 1
    grep -q '^CLAUDE=off$' "$p/.bx/config" || return 1

    bx_cmd "$p" claude on >/dev/null 2>&1 || return 1
    grep -q '^CLAUDE=on$' "$p/.bx/config" || return 1
}

test_3_old_config_missing_claude_no_crash() {
    local p
    p="$(new_project_dir test3)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    sed -i '/^CLAUDE=/d' "$p/.bx/config" || return 1

    # Regression check: this should not crash under set -e.
    bx_cmd "$p" claude >/dev/null 2>&1
}

test_4_old_config_missing_codex_no_crash() {
    local p
    p="$(new_project_dir test4)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    sed -i '/^CODEX=/d' "$p/.bx/config" || return 1

    # Regression check: this should not crash under set -e.
    bx_cmd "$p" codex >/dev/null 2>&1
}

test_4_claude_on_generates_minimal_state_and_copies_credentials() {
    local p
    p="$(new_project_dir test5)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" claude on >/dev/null 2>&1 || return 1
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    [[ -f "$p/.bx/home/.claude.json" ]] || return 1
    [[ -f "$p/.bx/home/.claude/.credentials.json" ]] || return 1
    jq -e --arg p "$p" '.hasCompletedOnboarding == true and .projects[$p].hasTrustDialogAccepted == true' "$p/.bx/home/.claude.json" >/dev/null || return 1
    ! grep -Fq '"dummy":true' "$p/.bx/home/.claude.json"
}

test_4b_claude_on_recreates_missing_claude_dir() {
    # Regression: fresh clone with committed .bx/config but gitignored .bx/home
    # left .bx/home/.claude missing, and `bx run` crashed trying to cp creds.
    local p
    p="$(new_project_dir test5b)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" claude on >/dev/null 2>&1 || return 1
    rm -rf "$p/.bx/home/.claude"

    bx_cmd "$p" run true >/dev/null 2>&1 || return 1

    [[ -f "$p/.bx/home/.claude/.credentials.json" ]]
}

test_5_claude_off_skips_claude_json() {
    local p
    p="$(new_project_dir test6)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" claude off >/dev/null 2>&1 || return 1
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    [[ ! -f "$p/.bx/home/.claude.json" ]] || return 1
    [[ ! -f "$p/.bx/home/.claude/.credentials.json" ]]
}

test_6_codex_on_copies_auth_json() {
    local p
    p="$(new_project_dir test7)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" codex on >/dev/null 2>&1 || return 1
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    [[ -f "$p/.bx/home/.codex/auth.json" ]]
}

test_7_codex_off_skips_auth_json() {
    local p
    p="$(new_project_dir test8)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" codex off >/dev/null 2>&1 || return 1
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    [[ ! -f "$p/.bx/home/.codex/auth.json" ]]
}

test_8_codex_run_generates_trust_config_and_refreshes_auth() {
    local p sandbox_conf sandbox_auth
    p="$(new_project_dir test8b)"
    sandbox_conf="$p/.bx/home/.codex/config.toml"
    sandbox_auth="$p/.bx/home/.codex/auth.json"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" codex on >/dev/null 2>&1 || return 1

    mkdir -p "$(dirname "$sandbox_conf")"
    printf '%s\n' 'sandbox_pref = "keep-me"' > "$sandbox_conf"
    printf '%s\n' '{"dummy":"old-sandbox-token"}' > "$sandbox_auth"
    printf '%s\n' 'host_pref = "from-host"' > "$HOST_HOME/.codex/config.toml"
    printf '%s\n' '{"dummy":"fresh-host-token"}' > "$HOST_HOME/.codex/auth.json"

    bx_cmd "$p" run true >/dev/null 2>&1 || true

    ! grep -Fxq 'host_pref = "from-host"' "$sandbox_conf" || return 1
    ! grep -Fxq 'sandbox_pref = "keep-me"' "$sandbox_conf" || return 1
    grep -Fxq "[projects.\"$p\"]" "$sandbox_conf" || return 1
    grep -Fxq 'trust_level = "trusted"' "$sandbox_conf" || return 1
    grep -Fq '"fresh-host-token"' "$sandbox_auth"
}

test_8c_pi_run_syncs_auth_models_and_targeted_settings() {
    local p sandbox_settings sandbox_models sandbox_mcp sandbox_auth
    p="$(new_project_dir test8c)"
    sandbox_settings="$p/.bx/home/.pi/agent/settings.json"
    sandbox_models="$p/.bx/home/.pi/agent/models.json"
    sandbox_mcp="$p/.bx/home/.pi/agent/mcp.json"
    sandbox_auth="$p/.bx/home/.pi/agent/auth.json"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    mkdir -p "$p/.bx/home/.pi/agent"
    printf '%s\n' '{"keepLocal":true,"defaultProvider":"old","defaultModel":"old-model"}' > "$sandbox_settings"
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    [[ -f "$sandbox_auth" ]] || return 1
    [[ -f "$sandbox_mcp" ]] || return 1
    jq -e '.mcpServers == {}' "$sandbox_mcp" >/dev/null || return 1
    [[ -f "$sandbox_settings" ]] || return 1
    jq -e '.keepLocal == true and .defaultProvider == "host" and .defaultModel == "host-model"' "$sandbox_settings" >/dev/null || return 1
    jq -e 'has("packages") | not' "$sandbox_settings" >/dev/null || return 1
    [[ -f "$sandbox_models" ]] || return 1
    cmp -s "$HOST_HOME/.pi/agent/models.json" "$sandbox_models" || return 1
}

test_8d_pi_run_syncs_model_keys_and_refreshes_models_json() {
    local p sandbox_settings sandbox_models
    p="$(new_project_dir test8d)"
    sandbox_settings="$p/.bx/home/.pi/agent/settings.json"
    sandbox_models="$p/.bx/home/.pi/agent/models.json"

    printf '%s\n' '{"defaultProvider":"openai-codex","defaultModel":"gpt-5.3-codex","defaultThinkingLevel":"medium","enabledModels":["gpt-*"],"packages":["leak"]}' > "$HOST_HOME/.pi/agent/settings.json"
    printf '%s\n' '{"providers":{"fresh":{"models":[{"id":"x"}]}}}' > "$HOST_HOME/.pi/agent/models.json"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    jq -e '.defaultProvider == "openai-codex" and .defaultModel == "gpt-5.3-codex" and .defaultThinkingLevel == "medium" and .enabledModels == ["gpt-*"]' "$sandbox_settings" >/dev/null || return 1
    jq -e 'has("packages") | not' "$sandbox_settings" >/dev/null || return 1
    cmp -s "$HOST_HOME/.pi/agent/models.json" "$sandbox_models" || return 1

    printf '%s\n' '{"other":true}' > "$HOST_HOME/.pi/agent/settings.json"
    rm -f "$HOST_HOME/.pi/agent/models.json"
    bx_cmd "$p" run true >/dev/null 2>&1 || true

    jq -e '(. | has("defaultProvider") | not) and (. | has("defaultModel") | not) and (. | has("defaultThinkingLevel") | not) and (. | has("enabledModels") | not)' "$sandbox_settings" >/dev/null || return 1
    [[ ! -e "$sandbox_models" ]]
}

test_9_mount_add_creates_entry() {
    local p src dst
    p="$(new_project_dir test9)"
    src="$p/src9"
    dst="/opt/test9"
    mkdir -p "$src"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src" "$dst" >/dev/null 2>&1 || return 1

    grep -Fqx "$src $dst" "$p/.bx/mounts"
}

test_10_mount_add_ro_creates_ro_entry() {
    local p src dst
    p="$(new_project_dir test10)"
    src="$p/src10"
    dst="/opt/test10"
    mkdir -p "$src"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src" "$dst" ro >/dev/null 2>&1 || return 1

    grep -Fqx "$src $dst" "$p/.bx/mounts"
}

test_11_mount_list_shows_entries() {
    local p src1 src2 dst1 dst2 out
    p="$(new_project_dir test11)"
    src1="$p/src11a"
    src2="$p/src11b"
    dst1="/opt/test11a"
    dst2="/opt/test11b"
    mkdir -p "$src1" "$src2"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src1" "$dst1" >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src2" "$dst2" ro >/dev/null 2>&1 || return 1
    out="$(bx_cmd "$p" mount list 2>/dev/null)" || return 1

    printf '%s\n' "$out" | grep -Fqx "$src1 $dst1" || return 1
    printf '%s\n' "$out" | grep -Fqx "$src2 $dst2" || return 1
}

test_12_mount_rm_removes_right_entry() {
    local p src1 src2 dst1 dst2
    p="$(new_project_dir test12)"
    src1="$p/src12a"
    src2="$p/src12b"
    dst1="/opt/test12a"
    dst2="/opt/test12b"
    mkdir -p "$src1" "$src2"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src1" "$dst1" >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src2" "$dst2" ro >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount rm "$dst1" >/dev/null 2>&1 || return 1

    ! grep -Fq "$src1 $dst1" "$p/.bx/mounts" || return 1
    grep -Fqx "$src2 $dst2" "$p/.bx/mounts"
}

test_13_mount_add_duplicate_dst_rejected() {
    local p src1 src2 dst
    p="$(new_project_dir test13)"
    src1="$p/src13a"
    src2="$p/src13b"
    dst="/opt/test13"
    mkdir -p "$src1" "$src2"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src1" "$dst" >/dev/null 2>&1 || return 1
    if bx_cmd "$p" mount add "$src2" "$dst" >/dev/null 2>&1; then
        return 1
    fi
}

test_14_mount_entry_applied_file_visible_in_sandbox() {
    local p src dst out
    p="$(new_project_dir test14)"
    src="$p/src14"
    dst="$HOME/mount14"
    mkdir -p "$src" "$p/.bx/home/mount14"
    printf 'hello-mount-14\n' > "$src/hello.txt"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    mkdir -p "$p/.bx/home/mount14"
    bx_cmd "$p" mount add "$src" "$dst" >/dev/null 2>&1 || return 1
    out="$(bx_cmd "$p" run cat "$HOME/mount14/hello.txt" 2>/dev/null)" || return 1

    [[ "$out" == "hello-mount-14" ]]
}

test_15_mount_trailing_whitespace_applied() {
    local p src dst out
    p="$(new_project_dir test15)"
    src="$p/src15"
    dst="$HOME/mount15"
    mkdir -p "$src"
    printf 'hello-mount-15\n' > "$src/hello.txt"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    mkdir -p "$p/.bx/home/mount15"
    printf '%s:%s   \n' "$src" "$dst" >> "$p/.bx/mounts"
    out="$(bx_cmd "$p" run cat "$HOME/mount15/hello.txt" 2>/dev/null)" || return 1

    [[ "$out" == "hello-mount-15" ]]
}

test_16_mount_add_relative_src_rejected() {
    local p dst
    p="$(new_project_dir test16)"
    dst="/opt/test16"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    mkdir -p "$p/rel-src"
    if bx_cmd "$p" mount add "rel-src" "$dst" >/dev/null 2>&1; then
        return 1
    fi
}

test_17_mount_add_invalid_mode_rejected() {
    local p src dst
    p="$(new_project_dir test17)"
    src="$p/src17"
    dst="/opt/test17"
    mkdir -p "$src"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    if bx_cmd "$p" mount add "$src" "$dst" invalid >/dev/null 2>&1; then
        return 1
    fi
}

test_18_mount_rm_nonexistent_dst_noop() {
    local p src dst existing before after
    p="$(new_project_dir test18)"
    src="$p/src18"
    dst="/opt/test18"
    existing="/opt/existing18"
    mkdir -p "$src"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bx_cmd "$p" mount add "$src" "$existing" >/dev/null 2>&1 || return 1
    before="$(cat "$p/.bx/mounts")"

    bx_cmd "$p" mount rm "$dst" >/dev/null 2>&1 || return 1
    after="$(cat "$p/.bx/mounts")"

    [[ "$before" == "$after" ]]
}

test_18b_init_preserves_existing_mounts_on_rerun() {
    local p src dst before after
    p="$(new_project_dir test18b)"
    src="$p/custom-src"
    dst="$HOME/custom-dst"
    mkdir -p "$src"

    mkdir -p "$p/.bx"
    printf '%s %s rw\n' "$src" "$dst" > "$p/.bx/mounts"
    before="$(cat "$p/.bx/mounts")"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    after="$(cat "$p/.bx/mounts")"

    [[ "$before" == "$after" ]]
}

test_19_init_writes_bashrc_v2_template() {
    local p bashrc
    p="$(new_project_dir test19)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bashrc="$p/.bx/home/.bashrc"

    [[ -f "$bashrc" ]] || return 1
    [[ "$(head -n 1 "$bashrc")" == "# bx-bashrc-version: 2" ]] || return 1
    grep -Fq 'if [[ -n "${BX_PROJECT_BIN:-}" ]]; then' "$bashrc" || return 1
    grep -Fq 'PATH="${PATH//:$BX_PROJECT_BIN:/:}"' "$bashrc"
}

test_20_run_migrates_legacy_bashrc_once() {
    local p bashrc out1 out2
    p="$(new_project_dir test20)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    bashrc="$p/.bx/home/.bashrc"
    printf '%s\n' 'export PATH="/tmp/host-prepend:$PATH"' > "$bashrc"

    out1="$(bx_cmd "$p" run true 2>&1)" || return 1
    printf '%s' "$out1" | grep -Fq '==> migrated .bx/home/.bashrc to v2' || return 1
    [[ "$(head -n 1 "$bashrc")" == "# bx-bashrc-version: 2" ]] || return 1

    out2="$(bx_cmd "$p" run true 2>&1)" || return 1
    ! printf '%s' "$out2" | grep -Fq '==> migrated .bx/home/.bashrc to v2'
}

test_21_run_scrubs_selected_env_and_preserves_api_keys() {
    local p out
    p="$(new_project_dir test21)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    # mise re-creates these inside the sandbox; we only care that host values don't survive.
    out="$(
        bx_cmd_env "$p" \
            "LD_LIBRARY_PATH=/tmp/ld-test" \
            "HOMEBREW_PREFIX=/opt/homebrew" \
            "INFOPATH=/tmp/info" \
            "__MISE_SESSION=test-mise-session" \
            "DIRENV_DIR=$p" \
            "ATUIN_SESSION=test-atuin-session" \
            "BLE_SESSION_ID=test-ble-session" \
            "STARSHIP_SESSION_KEY=test-starship-session" \
            "GROQ_API_KEY=groq-test-key" \
            "MISTRAL_API_KEY=mistral-test-key" \
            "XAI_API_KEY=xai-test-key" \
            "OLLAMA_API_KEY=ollama-test-key" \
            "OPENAI_API_KEY=openai-test-key" \
            "ANTHROPIC_API_KEY=anthropic-test-key" \
            -- run bash -lc 'printf "LD_LIBRARY_PATH=%s\nHOMEBREW_PREFIX=%s\nINFOPATH=%s\n__MISE_SESSION=%s\nDIRENV_DIR=%s\nATUIN_SESSION=%s\nBLE_SESSION_ID=%s\nSTARSHIP_SESSION_KEY=%s\nGROQ_API_KEY=%s\nMISTRAL_API_KEY=%s\nXAI_API_KEY=%s\nOLLAMA_API_KEY=%s\nOPENAI_API_KEY=%s\nANTHROPIC_API_KEY=%s\nPATH=%s\n" "${LD_LIBRARY_PATH-}" "${HOMEBREW_PREFIX-}" "${INFOPATH-}" "${__MISE_SESSION-}" "${DIRENV_DIR-}" "${ATUIN_SESSION-}" "${BLE_SESSION_ID-}" "${STARSHIP_SESSION_KEY-}" "${GROQ_API_KEY-}" "${MISTRAL_API_KEY-}" "${XAI_API_KEY-}" "${OLLAMA_API_KEY-}" "${OPENAI_API_KEY-}" "${ANTHROPIC_API_KEY-}" "${PATH-}"'
    )" || return 1

    printf '%s\n' "$out" | grep -Fxq 'LD_LIBRARY_PATH=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'HOMEBREW_PREFIX=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'INFOPATH=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'DIRENV_DIR=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'ATUIN_SESSION=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'BLE_SESSION_ID=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'STARSHIP_SESSION_KEY=' || return 1
    printf '%s\n' "$out" | grep -Fxq 'GROQ_API_KEY=groq-test-key' || return 1
    printf '%s\n' "$out" | grep -Fxq 'MISTRAL_API_KEY=mistral-test-key' || return 1
    printf '%s\n' "$out" | grep -Fxq 'XAI_API_KEY=xai-test-key' || return 1
    printf '%s\n' "$out" | grep -Fxq 'OLLAMA_API_KEY=ollama-test-key' || return 1
    printf '%s\n' "$out" | grep -Fxq 'OPENAI_API_KEY=openai-test-key' || return 1
    printf '%s\n' "$out" | grep -Fxq 'ANTHROPIC_API_KEY=anthropic-test-key' || return 1
    printf '%s\n' "$out" | grep -Eq "^PATH=$p/\.zcrew/bin:" || return 1
    printf '%s\n' "$out" | grep -Eq "^PATH=.*:${HOME//\//\\/}/.local/share/mise/shims:" || return 1
}

test_22_sandbox_tools_still_resolve() {
    local p out
    [[ "$HOST_LOCAL_AVAILABLE" -eq 1 ]] || return 0
    p="$(new_project_dir test22)"

    bx_cmd "$p" init >/dev/null 2>&1 || return 1
    # mise needs a project-local config so node/bun resolve inside the sandbox
    printf '[tools]\nnode = "22"\nbun = "latest"\n' > "$p/.mise.toml"
    (cd "$p" && mise trust .mise.toml >/dev/null 2>&1 && mise install >/dev/null 2>&1) || true
    out="$(bx_cmd "$p" run bash -lc 'printf "PATH=%s\n" "$PATH"; node --version >/dev/null; bun --version >/dev/null; rg --version >/dev/null; jq --version >/dev/null; for tool in mise bun rg jq node claude codex; do tool_path=$(command -v "$tool") || exit 1; printf "%s=%s\n" "$tool" "$tool_path"; done' 2>/dev/null)" || return 1

    printf '%s\n' "$out" | grep -Eq "^PATH=$p/\.zcrew/bin:" || return 1
    printf '%s\n' "$out" | grep -Eq "^PATH=.*:${HOME//\//\\/}/.local/share/mise/shims:" || return 1
    printf '%s\n' "$out" | grep -Eq "^node=${HOME//\//\\/}/.local/share/mise/(installs|shims)/" || return 1
    printf '%s\n' "$out" | grep -Eq "^bun=${HOME//\//\\/}/.local/share/mise/(installs|shims)/" || return 1
}

test_23_symlinked_standard_mount_resolves_target() {
    local p bx_copy fake_link fake_target mockbin args_file
    p="$(new_project_dir test23)"
    bx_copy="$p/bx-under-test"
    fake_link="$p/fake-usr-local-bin"
    fake_target="$p/real-usr-local-bin"
    mockbin="$p/mock-bin"
    args_file="$p/bwrap-args.txt"

    mkdir -p "$fake_target"
    ln -s "$fake_target" "$fake_link"
    cp "$BX_BIN" "$bx_copy" || return 1
    chmod +x "$bx_copy" || return 1
    sed -i "s|/usr/local/bin|$fake_link|g" "$bx_copy" || return 1
    make_mock_bwrap "$mockbin" "$args_file"

    (
        cd "$p" || exit 1
        env -u BX_INSIDE HOME="$HOST_HOME" PATH="$mockbin:$PATH" TERM="${TERM:-xterm-256color}" "$bx_copy" init >/dev/null 2>&1
    ) || return 1
    (
        cd "$p" || exit 1
        env -u BX_INSIDE HOME="$HOST_HOME" PATH="$mockbin:$PATH" TERM="${TERM:-xterm-256color}" MOCK_BWRAP_ARGS_FILE="$args_file" "$bx_copy" run true >/dev/null 2>&1
    ) || return 1

    grep -Fxq -- '--dir' "$args_file" || return 1
    grep -Fxq -- "$(dirname "$fake_target")" "$args_file" || return 1
    grep -Fxq -- '--ro-bind' "$args_file" || return 1
    grep -Fxq -- "$fake_target" "$args_file" || return 1

    awk -v parent="$(dirname "$fake_target")" -v src="$fake_target" '
        $0 == "--dir" {
            getline
            if ($0 == parent) saw_dir = 1
        }
        $0 == "--ro-bind" {
            getline
            if ($0 != src) next
            getline
            if ($0 == src) saw_bind = 1
        }
        END { exit(saw_dir && saw_bind ? 0 : 1) }
    ' "$args_file"
}

main() {
    mkdir -p "$BASE_PROJECT_ROOT"
    prepare_host_home

    run_test "1) bx init creates config with CLAUDE=on and CODEX=on" test_1_init_defaults
    run_test "2) bx claude off/on toggles work" test_2_claude_toggle
    run_test "3) bx claude (no arg) on old config missing CLAUDE does not crash" test_3_old_config_missing_claude_no_crash
    run_test "4) bx codex (no arg) on old config missing CODEX does not crash" test_4_old_config_missing_codex_no_crash
    run_test "5) CLAUDE=on: bx run true generates minimal .claude.json and copies .credentials.json" test_4_claude_on_generates_minimal_state_and_copies_credentials
    run_test "5b) CLAUDE=on: bx run recreates missing .bx/home/.claude dir" test_4b_claude_on_recreates_missing_claude_dir
    run_test "6) CLAUDE=off: bx run true leaves .claude.json and .claude/.credentials.json absent" test_5_claude_off_skips_claude_json
    run_test "7) CODEX=on: bx run true copies .codex/auth.json" test_6_codex_on_copies_auth_json
    run_test "8) CODEX=off: bx run true leaves .codex/auth.json absent" test_7_codex_off_skips_auth_json
    run_test "8b) CODEX=on: bx run generates trust config and refreshes auth.json" test_8_codex_run_generates_trust_config_and_refreshes_auth
    run_test "8c) bx run syncs pi auth/models and targeted settings" test_8c_pi_run_syncs_auth_models_and_targeted_settings
    run_test "8d) bx run refreshes pi model keys and removes stale models.json" test_8d_pi_run_syncs_model_keys_and_refreshes_models_json
    run_test "9) bx mount add creates entry in .bx/mounts" test_9_mount_add_creates_entry
    run_test "10) bx mount add [ro] creates :ro entry" test_10_mount_add_ro_creates_ro_entry
    run_test "11) bx mount list shows entries" test_11_mount_list_shows_entries
    run_test "12) bx mount rm removes the right entry" test_12_mount_rm_removes_right_entry
    run_test "13) bx mount add duplicate dst is rejected" test_13_mount_add_duplicate_dst_rejected
    run_test "14) mount entry applied: src file visible at dst in sandbox" test_14_mount_entry_applied_file_visible_in_sandbox
    run_test "15) trailing whitespace in mounts entry is handled" test_15_mount_trailing_whitespace_applied
    run_test "16) bx mount add with relative src is rejected" test_16_mount_add_relative_src_rejected
    run_test "17) bx mount add with invalid mode is rejected" test_17_mount_add_invalid_mode_rejected
    run_test "18) bx mount rm non-existent dst is silent no-op" test_18_mount_rm_nonexistent_dst_noop
    run_test "18b) bx init preserves existing .bx/mounts on re-run" test_18b_init_preserves_existing_mounts_on_rerun
    run_test "19) bx init writes the v2 bashrc template" test_19_init_writes_bashrc_v2_template
    run_test "20) bx run migrates a legacy bashrc exactly once" test_20_run_migrates_legacy_bashrc_once
    run_test "21) bx run scrubs selected env vars and preserves API keys" test_21_run_scrubs_selected_env_and_preserves_api_keys
    run_test "22) key sandbox tools still resolve inside bx" test_22_sandbox_tools_still_resolve
    run_test "23) symlinked standard mount resolves target before bind" test_23_symlinked_standard_mount_resolves_target

    echo ""
    echo "Total: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"
