# zcrew on macOS via Colima

zcrew remains **Linux-only**. On macOS, the supported path is: run the orchestrator, tmux/zellij, workers, and `bx` **inside a Colima Linux VM**. The macOS host only starts the VM and gives you a clean way to enter it.

## Happy path

1. Install Colima on the macOS host.

```bash
brew install colima
```

2. Bootstrap the VM from this repo.

```bash
./setup-macos-colima.sh
```

The script:
- hard-gates on macOS
- reuses or starts a Colima profile named `zcrew`
- uses `containerd` runtime, so Docker/Podman are not required
- preinstalls `tmux`, `zellij`, `jq`, `git`, `python3`, `build-essential`, and `mise` inside the VM
- opens an interactive shell in the VM when finished

3. From the macOS host, re-enter the VM later with:

```bash
bin/zcrew-mac /Users/$USER/Projects/your-project
```

If you run `bin/zcrew-mac` while your host shell is already inside `/Users/$USER/...`, it uses the current directory automatically.

4. Inside the VM, install zcrew into a project and work normally:

```bash
cd /Users/$USER/Projects/your-project
.zcrew/bin/zcrew install .
tmux    # or zellij
zcrew claim
zcrew spawn claude claudio
zcrew send claudio "ping"
```

## Mounts and paths

The supported happy path is a project tree under `/Users/$USER/...`, typically `/Users/$USER/Projects`. Colima exposes host home paths inside the VM, which keeps the same path on both sides and makes `bin/zcrew-mac` simple.

If your projects live outside `/Users/$USER/...`, this bootstrap does **not** set up custom mounts for you. Use a Colima profile config or Lima override and mount that path manually, then re-run the wrapper with the in-VM path you chose.

## Apple Silicon and Intel

- Apple Silicon: the setup script prefers Colima's `vz` VM type.
- Intel: the script falls back to the standard Colima VM start path.

## Case-sensitivity caveat

macOS host filesystems are usually case-insensitive while Linux inside Colima is case-sensitive. Avoid case-only renames in Git unless your host filesystem is configured for them.

## What runs where

- macOS host: `colima`, `setup-macos-colima.sh`, `bin/zcrew-mac`
- Colima VM: orchestrator, `tmux`/`zellij`, Claude/Codex/Pi, zcrew, `bx`, worker panes

## What you need to verify on a real Mac

This repo can test host-side argument handling and dry-run behavior in CI-like shell tests, but it cannot validate Colima boot, package installation, or interactive shell handoff from Linux CI.

Use this manual check sequence on macOS:

```bash
brew install colima
./setup-macos-colima.sh
bin/zcrew-mac /Users/$USER/Projects/your-project
cd /Users/$USER/Projects/your-project
.zcrew/bin/zcrew install .
tmux
zcrew claim
zcrew spawn claude claudio
zcrew list
zcrew send claudio "ping"
```

Success criteria:
- `colima list` shows profile `zcrew` in `Running`
- `tmux` or `zellij` works inside the VM
- `zcrew list` shows `main` as `alive`
- spawned worker appears as `alive`
- worker can reply back to `main`
