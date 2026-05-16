#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "zcrew macOS setup only runs on macOS hosts. zcrew itself stays Linux-only inside Colima." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: setup-macos-colima.sh [options]

Bootstrap a Colima-backed Linux VM for running zcrew entirely inside Linux.

Options:
  --profile NAME        Colima profile name (default: zcrew)
  --projects-root PATH  Host projects root to access inside the VM (default: ~/Projects)
  --cpu N               VM CPU count (default: 4)
  --memory GiB          VM memory in GiB (default: 8)
  --disk GiB            VM disk size in GiB (default: 60)
  --dry-run             Print actions without changing the host or VM
  -h, --help            Show this help
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'setup-macos-colima: %s\n' "$*" >&2
  exit 1
}

expand_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    ~/*) printf '%s\n' "$HOME/${path#~/}" ;;
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$PWD/$path" ;;
  esac
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

vm_status() {
  colima list 2>/dev/null | awk -v profile="$PROFILE" '$1 == profile { print $2; exit }'
}

ensure_host_requirements() {
  if ! command -v colima >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      die "colima is not installed. Install it with: brew install colima"
    fi
    die "Homebrew is not installed. Install Homebrew, then run: brew install colima"
  fi
}

ensure_projects_root() {
  if [[ "$PROJECTS_ROOT" != "/Users/$USER/"* && "$PROJECTS_ROOT" != "/Users/$USER" ]]; then
    die "projects root must live under /Users/$USER for the same-path Colima happy path. See docs/macos-colima.md for fallback mounts."
  fi

  if [[ ! -d "$PROJECTS_ROOT" ]]; then
    log "Creating host projects root at $PROJECTS_ROOT"
    run_cmd mkdir -p "$PROJECTS_ROOT"
  fi
}

start_or_reuse_vm() {
  local arch vm_status_now
  arch="$(uname -m)"
  vm_status_now="$(vm_status || true)"

  if [[ "$vm_status_now" == "Running" ]]; then
    log "Reusing running Colima profile '$PROFILE'"
    return 0
  fi

  log "Starting Colima profile '$PROFILE'"
  if [[ "$arch" == "arm64" ]]; then
    run_cmd colima start --profile "$PROFILE" --runtime containerd --cpu "$CPU" --memory "$MEMORY" --disk "$DISK" --vm-type vz
  else
    run_cmd colima start --profile "$PROFILE" --runtime containerd --cpu "$CPU" --memory "$MEMORY" --disk "$DISK"
  fi
}

bootstrap_vm() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+ colima ssh --profile %q -- bash -s # bootstrap tmux zellij jq git mise\n' "$PROFILE"
    return 0
  fi

  colima ssh --profile "$PROFILE" -- bash -s <<'EOF'
set -euo pipefail

missing_packages=()
for pkg in build-essential curl git jq python3 tmux zellij; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing_packages+=("$pkg")
  fi
done

if ((${#missing_packages[@]} > 0)); then
  sudo apt-get update
  sudo apt-get install -y "${missing_packages[@]}"
fi

if ! command -v mise >/dev/null 2>&1; then
  curl https://mise.run | sh
fi

if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
fi
EOF
}

open_vm_shell() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+ colima ssh --profile %q\n' "$PROFILE"
    return 0
  fi

  log "Opening a Linux shell inside profile '$PROFILE'"
  exec colima ssh --profile "$PROFILE"
}

PROFILE="zcrew"
PROJECTS_ROOT="$HOME/Projects"
CPU="4"
MEMORY="8"
DISK="60"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      [[ -n "$PROFILE" ]] || die "--profile requires a value"
      shift 2
      ;;
    --projects-root)
      PROJECTS_ROOT="${2:-}"
      [[ -n "$PROJECTS_ROOT" ]] || die "--projects-root requires a value"
      shift 2
      ;;
    --cpu)
      CPU="${2:-}"
      [[ "$CPU" =~ ^[0-9]+$ ]] || die "--cpu must be an integer"
      shift 2
      ;;
    --memory)
      MEMORY="${2:-}"
      [[ "$MEMORY" =~ ^[0-9]+$ ]] || die "--memory must be an integer GiB value"
      shift 2
      ;;
    --disk)
      DISK="${2:-}"
      [[ "$DISK" =~ ^[0-9]+$ ]] || die "--disk must be an integer GiB value"
      shift 2
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

PROJECTS_ROOT="$(expand_path "$PROJECTS_ROOT")"

ensure_host_requirements
ensure_projects_root
start_or_reuse_vm
bootstrap_vm
open_vm_shell
