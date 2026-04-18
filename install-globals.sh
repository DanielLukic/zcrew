#!/usr/bin/env bash
set -euo pipefail

dry_run="false"
include_zcrew="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run="true"
      ;;
    --include-zcrew)
      include_zcrew="true"
      ;;
    *)
      echo "Usage: ./install-globals.sh [--dry-run] [--include-zcrew]" >&2
      exit 1
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="$HOME/.local/bin"
systemd_target_dir="$HOME/.config/systemd/user"

for tool in bx ix claude-auth-sync; do
  src="$repo_root/bin/$tool"
  dst="$target_dir/$tool"
  backup="$dst.bak"
  [[ -f "$src" ]] || { echo "missing source: $src" >&2; exit 1; }

  if [[ "$dry_run" == "true" ]]; then
    if [[ -e "$dst" ]]; then
      echo "would back up $dst to $backup"
    fi
    echo "would install $src to $dst"
    continue
  fi

  mkdir -p "$target_dir"
  if [[ -e "$dst" ]]; then
    cp "$dst" "$backup"
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "installed $tool to $dst (backup at $backup)"
done

for unit in claude-auth-sync.service claude-auth-sync.path; do
  src="$repo_root/lib/ix/systemd/$unit"
  dst="$systemd_target_dir/$unit"
  [[ -f "$src" ]] || { echo "missing source: $src" >&2; exit 1; }

  if [[ "$dry_run" == "true" ]]; then
    echo "would install $src to $dst"
    continue
  fi

  mkdir -p "$systemd_target_dir"
  cp "$src" "$dst"
  echo "installed $unit to $dst"
done

if [[ "$dry_run" == "true" ]]; then
  echo "would run systemctl --user daemon-reload"
else
  systemctl --user daemon-reload
  echo "ran systemctl --user daemon-reload"
  if ! systemctl --user is-enabled claude-auth-sync.path &>/dev/null; then
    echo "  → to activate auth sync: systemctl --user enable --now claude-auth-sync.path"
  fi
fi

if [[ "$include_zcrew" == "true" ]]; then
  codex_src="$repo_root/.codex/skills/zcrew/"
  codex_dst="$HOME/.codex/skills/zcrew/"
  [[ -d "$codex_src" ]] || { echo "missing source: $codex_src" >&2; exit 1; }

  if [[ "$dry_run" == "true" ]]; then
    echo "would sync $codex_src to $codex_dst"
  else
    mkdir -p "$HOME/.codex/skills"
    rsync -a --delete "$codex_src" "$codex_dst"
    echo "synced $codex_src to $codex_dst"
  fi

  pi_target_root="$HOME/.pi/agent/skills"
  [[ -d "$repo_root/.pi/skills" ]] || { echo "missing source: $repo_root/.pi/skills" >&2; exit 1; }
  for skill in zcrew zspawn zsend zpanes zsync zname zclose; do
    pi_src="$repo_root/.pi/skills/$skill/"
    pi_dst="$pi_target_root/$skill/"
    [[ -d "$pi_src" ]] || { echo "missing source: $pi_src" >&2; exit 1; }

    if [[ "$dry_run" == "true" ]]; then
      echo "would sync $pi_src to $pi_dst"
      continue
    fi

    mkdir -p "$pi_target_root"
    rsync -a --delete "$pi_src" "$pi_dst"
    echo "synced $pi_src to $pi_dst"
  done
fi
