#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IX_BIN="$REPO_ROOT/bin/ix"
TMP_ROOT="$REPO_ROOT/.tmp"
BASE_PROJECT_ROOT="$TMP_ROOT/test-ix"
HOST_HOME="$TMP_ROOT/host-home-ix"
MOCK_BIN="$TMP_ROOT/mock-bin"
MOCK_INCUS_STATE="$TMP_ROOT/mock-incus-state"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

prepare_host_home() {
    rm -rf "$HOST_HOME"
    mkdir -p "$HOST_HOME/.claude" "$HOST_HOME/.codex"
    printf '{"dummy":true}\n' > "$HOST_HOME/.claude.json"
    printf '{"dummy":true}\n' > "$HOST_HOME/.claude/.credentials.json"
    printf '{"dummy":true}\n' > "$HOST_HOME/.codex/auth.json"
    printf 'model = "dummy"\n' > "$HOST_HOME/.codex/config.toml"
    # Keep setup_mounts() from returning non-zero on trailing [[ -f ~/.bash_aliases ]] checks.
    printf '# test aliases\n' > "$HOST_HOME/.bash_aliases"
}

prepare_mock_bin() {
    rm -rf "$MOCK_BIN" "$MOCK_INCUS_STATE"
    mkdir -p "$MOCK_BIN" "$MOCK_INCUS_STATE"

    cat > "$MOCK_BIN/incus" <<'MOCK_INCUS'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${MOCK_INCUS_STATE:?MOCK_INCUS_STATE is required}"
CONTAINERS_DIR="$STATE_DIR/containers"
mkdir -p "$CONTAINERS_DIR"

container_dir() {
    printf '%s/%s\n' "$CONTAINERS_DIR" "$1"
}

ensure_container() {
    local cdir
    cdir="$(container_dir "$1")"
    [[ -d "$cdir" ]]
}

read_state() {
    local cdir
    cdir="$(container_dir "$1")"
    if [[ -f "$cdir/state" ]]; then
        cat "$cdir/state"
    else
        echo "RUNNING"
    fi
}

write_state() {
    local cdir
    cdir="$(container_dir "$1")"
    mkdir -p "$cdir"
    printf '%s\n' "$2" > "$cdir/state"
}

show_devices() {
    local cdir devfile
    cdir="$(container_dir "$1")"
    devfile="$cdir/devices"
    [[ -f "$devfile" ]] || return 0
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        printf '%s:\n' "$dev"
        printf '  type: disk\n'
    done < "$devfile"
}

add_device() {
    local cdir devfile name
    cdir="$(container_dir "$1")"
    name="$2"
    devfile="$cdir/devices"
    mkdir -p "$cdir"
    touch "$devfile"
    grep -qxF "$name" "$devfile" || echo "$name" >> "$devfile"
}

remove_device() {
    local cdir devfile name tmpfile
    cdir="$(container_dir "$1")"
    name="$2"
    devfile="$cdir/devices"
    [[ -f "$devfile" ]] || return 0
    tmpfile="$devfile.tmp"
    grep -vxF "$name" "$devfile" > "$tmpfile" || true
    mv "$tmpfile" "$devfile"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || exit 0
shift || true

case "$cmd" in
    launch)
        image="$1"
        container="$2"
        cdir="$(container_dir "$container")"
        mkdir -p "$cdir"
        printf '%s\n' "$image" > "$cdir/image"
        write_state "$container" "RUNNING"
        ;;
    info)
        container="$1"
        if ! ensure_container "$container"; then
            echo "Error: not found" >&2
            exit 1
        fi
        state="$(read_state "$container")"
        cat <<EOF2
Name: $container
Status: $state
Type: container
Created: mock
Last Used: mock
EOF2
        ;;
    restart)
        container="$1"
        ensure_container "$container" || exit 1
        write_state "$container" "RUNNING"
        ;;
    start)
        container="$1"
        ensure_container "$container" || exit 1
        write_state "$container" "RUNNING"
        ;;
    stop)
        container="$1"
        ensure_container "$container" || exit 1
        write_state "$container" "STOPPED"
        ;;
    delete)
        container="$1"
        rm -rf "$(container_dir "$container")"
        ;;
    config)
        sub="$1"
        shift
        case "$sub" in
            set)
                container="$1"; key="$2"; value="$3"
                cdir="$(container_dir "$container")"
                mkdir -p "$cdir"
                printf '%s=%s\n' "$key" "$value" >> "$cdir/config-kv"
                ;;
            device)
                action="$1"
                shift
                case "$action" in
                    add)
                        container="$1"
                        name="$2"
                        add_device "$container" "$name"
                        ;;
                    show)
                        container="$1"
                        show_devices "$container"
                        ;;
                    remove)
                        container="$1"
                        name="$2"
                        remove_device "$container" "$name"
                        ;;
                    *)
                        exit 1
                        ;;
                esac
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    exec)
        # Consume stdin (ix uses heredocs) and succeed.
        cat >/dev/null || true
        exit 0
        ;;
    file)
        sub="$1"
        shift
        case "$sub" in
            push)
                # No-op for tests.
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        # Allow unsupported commands to no-op for future-proofing tests.
        exit 0
        ;;
esac
MOCK_INCUS

    cat > "$MOCK_BIN/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP

    chmod +x "$MOCK_BIN/incus" "$MOCK_BIN/sleep"
}

new_project_dir() {
    local name="$1"
    local project_dir="$BASE_PROJECT_ROOT/$name"
    rm -rf "$project_dir"
    mkdir -p "$project_dir"
    printf '%s\n' "$project_dir"
}

ix_cmd() {
    local project_dir="$1"
    shift
    (
        cd "$project_dir" || exit 1
        env -u BX_INSIDE \
        HOME="$HOST_HOME" \
        PATH="$MOCK_BIN:$PATH" \
        MOCK_INCUS_STATE="$MOCK_INCUS_STATE" \
        TERM="${TERM:-xterm-256color}" \
        "$IX_BIN" "$@"
    )
}

device_name_for_dst() {
    local dst="$1"
    local hash
    hash="$(printf '%s' "$dst" | sha1sum | awk '{print substr($1,1,12)}')"
    printf 'custom-mount-%s\n' "$hash"
}

mock_device_list() {
    local project_dir="$1"
    local container
    container="$(awk -F= '/^CONTAINER=/{print $2}' "$project_dir/.ix/config")"
    MOCK_INCUS_STATE="$MOCK_INCUS_STATE" "$MOCK_BIN/incus" config device show "$container"
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

test_1_setup_writes_flag_defaults() {
    local p
    p="$(new_project_dir test1)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1

    grep -q '^CLAUDE=on$' "$p/.ix/config" || return 1
    grep -q '^CODEX=on$' "$p/.ix/config" || return 1
}

test_2_claude_toggle() {
    local p
    p="$(new_project_dir test2)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1

    ix_cmd "$p" claude off >/dev/null 2>&1 || return 1
    grep -q '^CLAUDE=off$' "$p/.ix/config" || return 1

    ix_cmd "$p" claude on >/dev/null 2>&1 || return 1
    grep -q '^CLAUDE=on$' "$p/.ix/config" || return 1
}

test_3_old_config_missing_claude_no_crash() {
    local p
    p="$(new_project_dir test3)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    sed -i '/^CLAUDE=/d' "$p/.ix/config" || return 1

    ix_cmd "$p" claude >/dev/null 2>&1
}

test_4_codex_toggle() {
    local p
    p="$(new_project_dir test4)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1

    ix_cmd "$p" codex off >/dev/null 2>&1 || return 1
    grep -q '^CODEX=off$' "$p/.ix/config" || return 1

    ix_cmd "$p" codex on >/dev/null 2>&1 || return 1
    grep -q '^CODEX=on$' "$p/.ix/config" || return 1
}

test_5_old_config_missing_codex_no_crash() {
    local p
    p="$(new_project_dir test5)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    sed -i '/^CODEX=/d' "$p/.ix/config" || return 1

    ix_cmd "$p" codex >/dev/null 2>&1
}

test_6_status_shows_claude_and_codex_values() {
    local p out
    p="$(new_project_dir test6)"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" claude off >/dev/null 2>&1 || return 1
    ix_cmd "$p" codex on >/dev/null 2>&1 || return 1

    out="$(ix_cmd "$p" status 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -Eq '^CLAUDE:[[:space:]]+off$' || return 1
    printf '%s\n' "$out" | grep -Eq '^CODEX:[[:space:]]+on$' || return 1
}

test_7_mount_add_creates_entry() {
    local p src dst
    p="$(new_project_dir test7)"
    src="$p/src7"
    dst="/opt/test7"
    mkdir -p "$src"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src" "$dst" >/dev/null 2>&1 || return 1

    grep -Fqx "$src $dst" "$p/.ix/mounts"
}

test_8_mount_add_ro_creates_ro_entry() {
    local p src dst
    p="$(new_project_dir test8)"
    src="$p/src8"
    dst="/opt/test8"
    mkdir -p "$src"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src" "$dst" ro >/dev/null 2>&1 || return 1

    grep -Fqx "$src $dst" "$p/.ix/mounts"
}

test_9_mount_list_shows_entries() {
    local p src1 src2 dst1 dst2 out
    p="$(new_project_dir test9)"
    src1="$p/src9a"
    src2="$p/src9b"
    dst1="/opt/test9a"
    dst2="/opt/test9b"
    mkdir -p "$src1" "$src2"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src1" "$dst1" >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src2" "$dst2" ro >/dev/null 2>&1 || return 1
    out="$(ix_cmd "$p" mount list 2>/dev/null)" || return 1

    printf '%s\n' "$out" | grep -Fqx "$src1 $dst1" || return 1
    printf '%s\n' "$out" | grep -Fqx "$src2 $dst2" || return 1
}

test_10_mount_rm_removes_right_entry() {
    local p src1 src2 dst1 dst2
    p="$(new_project_dir test10)"
    src1="$p/src10a"
    src2="$p/src10b"
    dst1="/opt/test10a"
    dst2="/opt/test10b"
    mkdir -p "$src1" "$src2"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src1" "$dst1" >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src2" "$dst2" ro >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount rm "$dst1" >/dev/null 2>&1 || return 1

    ! grep -Fq "$src1 $dst1" "$p/.ix/mounts" || return 1
    grep -Fqx "$src2 $dst2" "$p/.ix/mounts"
}

test_11_mount_add_duplicate_dst_rejected() {
    local p src1 src2 dst
    p="$(new_project_dir test11)"
    src1="$p/src11a"
    src2="$p/src11b"
    dst="/opt/test11"
    mkdir -p "$src1" "$src2"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src1" "$dst" >/dev/null 2>&1 || return 1
    if ix_cmd "$p" mount add "$src2" "$dst" >/dev/null 2>&1; then
        return 1
    fi
}

test_12_mount_add_relative_src_rejected() {
    local p dst
    p="$(new_project_dir test12)"
    dst="/opt/test12"
    mkdir -p "$p/rel-src"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    if ix_cmd "$p" mount add "rel-src" "$dst" >/dev/null 2>&1; then
        return 1
    fi
}

test_13_mount_add_invalid_mode_rejected() {
    local p src dst
    p="$(new_project_dir test13)"
    src="$p/src13"
    dst="/opt/test13"
    mkdir -p "$src"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    if ix_cmd "$p" mount add "$src" "$dst" invalid >/dev/null 2>&1; then
        return 1
    fi
}

test_14_mount_rm_nonexistent_dst_noop() {
    local p src dst existing before after
    p="$(new_project_dir test14)"
    src="$p/src14"
    dst="/opt/test14"
    existing="/opt/existing14"
    mkdir -p "$src"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    ix_cmd "$p" mount add "$src" "$existing" >/dev/null 2>&1 || return 1
    before="$(cat "$p/.ix/mounts")"

    ix_cmd "$p" mount rm "$dst" >/dev/null 2>&1 || return 1
    after="$(cat "$p/.ix/mounts")"

    [[ "$before" == "$after" ]]
}

test_15_setup_applies_hashed_custom_mount_devices() {
    local p src1 src2 dst1 dst2 dev1 dev2 devices
    p="$(new_project_dir test15)"
    src1="$p/src15a"
    src2="$p/src15b"
    dst1="/opt/test15a"
    dst2="/opt/test15b"
    mkdir -p "$src1" "$src2" "$p/.ix"
    printf '%s:%s\n' "$src1" "$dst1" > "$p/.ix/mounts"
    printf '%s:%s:ro\n' "$src2" "$dst2" >> "$p/.ix/mounts"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    devices="$(mock_device_list "$p")" || return 1
    dev1="$(device_name_for_dst "$dst1")"
    dev2="$(device_name_for_dst "$dst2")"

    printf '%s\n' "$devices" | grep -q "^${dev1}:$" || return 1
    printf '%s\n' "$devices" | grep -q "^${dev2}:$" || return 1
}

test_16_mount_rm_removes_live_device() {
    local p src1 src2 dst1 dst2 dev1 dev2 devices
    p="$(new_project_dir test16)"
    src1="$p/src16a"
    src2="$p/src16b"
    dst1="/opt/test16a"
    dst2="/opt/test16b"
    mkdir -p "$src1" "$src2" "$p/.ix"
    printf '%s:%s\n' "$src1" "$dst1" > "$p/.ix/mounts"
    printf '%s:%s\n' "$src2" "$dst2" >> "$p/.ix/mounts"

    ix_cmd "$p" setup >/dev/null 2>&1 || return 1
    dev1="$(device_name_for_dst "$dst1")"
    dev2="$(device_name_for_dst "$dst2")"
    devices="$(mock_device_list "$p")" || return 1
    printf '%s\n' "$devices" | grep -q "^${dev1}:$" || return 1

    ix_cmd "$p" mount rm "$dst1" >/dev/null 2>&1 || return 1
    devices="$(mock_device_list "$p")" || return 1
    ! printf '%s\n' "$devices" | grep -q "^${dev1}:$" || return 1
    printf '%s\n' "$devices" | grep -q "^${dev2}:$"
}

main() {
    mkdir -p "$BASE_PROJECT_ROOT"
    prepare_host_home
    prepare_mock_bin

    run_test "1) ix setup writes CLAUDE=on and CODEX=on" test_1_setup_writes_flag_defaults
    run_test "2) ix claude off/on toggles work" test_2_claude_toggle
    run_test "3) ix claude (no arg) on old config missing CLAUDE key does not crash" test_3_old_config_missing_claude_no_crash
    run_test "4) ix codex off/on toggles work" test_4_codex_toggle
    run_test "5) ix codex (no arg) on old config missing CODEX key does not crash" test_5_old_config_missing_codex_no_crash
    run_test "6) ix status shows CLAUDE and CODEX values" test_6_status_shows_claude_and_codex_values
    run_test "7) ix mount add creates entry in .ix/mounts" test_7_mount_add_creates_entry
    run_test "8) ix mount add [ro] creates :ro entry" test_8_mount_add_ro_creates_ro_entry
    run_test "9) ix mount list shows entries" test_9_mount_list_shows_entries
    run_test "10) ix mount rm removes right entry from .ix/mounts" test_10_mount_rm_removes_right_entry
    run_test "11) ix mount add duplicate dst is rejected" test_11_mount_add_duplicate_dst_rejected
    run_test "12) ix mount add relative src is rejected" test_12_mount_add_relative_src_rejected
    run_test "13) ix mount add invalid mode is rejected" test_13_mount_add_invalid_mode_rejected
    run_test "14) ix mount rm non-existent dst is silent no-op" test_14_mount_rm_nonexistent_dst_noop
    run_test "15) ix setup applies hashed custom-mount devices from .ix/mounts" test_15_setup_applies_hashed_custom_mount_devices
    run_test "16) ix mount rm removes live hashed custom-mount device" test_16_mount_rm_removes_live_device

    echo ""
    echo "Total: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"
