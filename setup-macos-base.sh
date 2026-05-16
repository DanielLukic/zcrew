#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "setup-macos-base.sh only runs on macOS hosts. zcrew itself stays Linux-only inside Lima." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: setup-macos-base.sh [--rebuild] [--dry-run]

Build or refresh the shared zcrew-base Lima instance used as the clone source
for per-project macOS VMs.
EOF
}

die() {
  printf 'setup-macos-base: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

instance_exists() {
  limactl list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$BASE_INSTANCE"
}

ensure_lima() {
  if command -v limactl >/dev/null 2>&1; then
    return 0
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew is required to install Lima. Install brew first."
  log "Installing Lima with Homebrew"
  run_cmd brew install lima
}

rebuild_base_if_requested() {
  if [[ "$REBUILD" != "true" ]]; then
    return 0
  fi
  if instance_exists; then
    log "Deleting existing base instance '$BASE_INSTANCE'"
    run_cmd limactl delete --force "$BASE_INSTANCE"
  fi
}

ensure_base_instance() {
  if instance_exists; then
    return 0
  fi
  log "Creating base instance '$BASE_INSTANCE'"
  run_cmd limactl start --name="$BASE_INSTANCE" --tty=false --vm-type=vz --mount-type=virtiofs --mount-none template:ubuntu
}

provision_base() {
  local marker="/var/lib/zcrew-base/version-$BASE_VERSION"
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+ limactl shell --workdir /tmp %q sudo test -f %q\n' "$BASE_INSTANCE" "$marker"
    printf '+ limactl shell --workdir /tmp %q bash -lc %q\n' "$BASE_INSTANCE" "sudo apt-get update && sudo apt-get install -y tmux zellij jq git curl build-essential python3 && curl https://mise.run | sh && sudo mkdir -p /var/lib/zcrew-base && sudo touch $marker"
    return 0
  fi

  if limactl shell --workdir /tmp "$BASE_INSTANCE" sudo test -f "$marker" >/dev/null 2>&1; then
    log "Base instance '$BASE_INSTANCE' is already provisioned"
    return 0
  fi

  log "Provisioning '$BASE_INSTANCE'"
  limactl shell --workdir /tmp "$BASE_INSTANCE" bash -lc "
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y tmux zellij jq git curl build-essential python3
    if ! command -v mise >/dev/null 2>&1; then
      curl https://mise.run | sh
    fi
    if ! grep -Fqx 'export PATH=\"\$HOME/.local/bin:\$PATH\"' \"\$HOME/.bashrc\" 2>/dev/null; then
      printf '\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n' >> \"\$HOME/.bashrc\"
    fi
    sudo mkdir -p /var/lib/zcrew-base
    sudo touch '$marker'
  "
}

stop_base() {
  log "Stopping '$BASE_INSTANCE'"
  run_cmd limactl stop "$BASE_INSTANCE"
}

BASE_INSTANCE="zcrew-base"
BASE_VERSION="1"
DRY_RUN="false"
REBUILD="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

ensure_lima
rebuild_base_if_requested
ensure_base_instance
provision_base
stop_base
