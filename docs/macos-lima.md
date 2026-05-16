# zcrew on macOS via per-project Lima VMs

zcrew remains **Linux-only**. On macOS, the supported path is: build one shared Lima base VM, then clone a cheap per-project VM from it. Each project gets its own Linux machine, its own mounted source tree, and its own RAM only while running.

## Happy path

```bash
brew install lima
./setup-macos-base.sh
./bin/zcrew-mac install ~/Projects/foo
./bin/zcrew-mac enter ~/Projects/foo
```

Inside the project VM:

```bash
tmux    # or zellij
zcrew claim
zcrew spawn claude claudio
```

## What the scripts do

`setup-macos-base.sh`:
- hard-gates on macOS
- installs Lima via Homebrew if needed
- creates or refreshes the shared `zcrew-base` instance
- provisions Ubuntu with `tmux`, `zellij`, `jq`, `mise`, `git`, `curl`, `build-essential`, and `python3`
- stops the base instance when finished
- supports `--rebuild` for a forced refresh

`bin/zcrew-mac`:
- `install <project>` clones `zcrew-base`, mounts only that project path, runs `zcrew install .` inside the VM, then enters the shell
- `enter <project>` starts the VM if needed and enters at the project path
- `stop <project>` stops the VM
- `destroy <project>` deletes the VM
- `list` shows `zcrew-*` Lima instances

## VM naming

Per-project VMs are named:

```text
zcrew-<basename>-<sha256(abs_path)[:8]>
```

That keeps names stable and avoids collisions for paths like `~/work/foo` and `~/code/foo`.

## Mount behavior

The project path is mounted into the guest at the **same absolute path** and is writable. In v1, `zcrew-mac install` mounts **only** that project path, not your entire home directory.

## Lifecycle

There is no auto-suspend in v1. Use explicit commands:

```bash
./bin/zcrew-mac stop ~/Projects/foo
./bin/zcrew-mac destroy ~/Projects/foo
```

## What runs where

- macOS host: Lima, `setup-macos-base.sh`, `bin/zcrew-mac`
- per-project Lima VM: orchestrator, `tmux`/`zellij`, Claude/Codex/Pi, zcrew, `bx`, worker panes

## What you need to verify on a real Mac

This repo can test Darwin gating, dry-run output, and VM-name derivation from Linux CI, but it cannot validate real Lima boot, cloning, package provisioning, or interactive shell handoff from this environment.

Manual macOS check:

```bash
brew install lima
./setup-macos-base.sh
./bin/zcrew-mac install ~/Projects/foo
./bin/zcrew-mac list
./bin/zcrew-mac enter ~/Projects/foo
```

Inside the VM:

```bash
tmux
zcrew claim
zcrew spawn claude claudio
zcrew list
zcrew send claudio "ping"
```

Success criteria:
- `limactl list` shows `zcrew-base` plus one `zcrew-*` project VM
- `zcrew-mac enter` lands in the mounted project path
- `zcrew list` shows `main` as `alive`
- a spawned worker appears as `alive`
- the worker can reply to `main`
