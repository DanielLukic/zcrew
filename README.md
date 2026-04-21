# zcrew

**zcrew** is a quick-win multi-agent CLI: clone, install, and run Claude, Codex, or Pi agents in [zellij](https://zellij.dev) panes, each sandboxed via [bwrap](https://github.com/containers/bubblewrap). A low-ceremony orchestrator for micro-managers like me who want to watch all their little agents at work.

The default sandbox model is intentionally minimal. zcrew does **not** mount or copy your full host `~/.claude`, `~/.codex`, `~/.pi`, or `~/.local` trees into agent panes. Instead, each project gets a clean sandbox-local HOME under `.bx/home/`, a narrow runtime mount allowlist, copied auth artifacts, and tiny generated config files.

That means your normal Claude/Codex auth keeps working seamlessly inside the sandbox — including subscription-backed logins — without dragging in your full personal agent state, MCP setup, extensions, caches, or history from the host. Sessions and runtime state still persist, but only inside the project sandbox.

## What it does

- **Spawn** named agent panes: `zcrew spawn claude claudio`, `zcrew spawn codex sam`, `zcrew spawn pi piper`
- **Send** tasks between agents: `zcrew send --compact sam "implement TFD-42: add retry logic"`
- **List** the team: `zcrew list`
- **Sync** registry with live zellij state (auto-syncs on every command)
- **Close** / **rename** panes

Each agent runs inside a bwrap sandbox (`bx`) with isolated HOME, scrubbed env vars, and project-local tool resolution via [mise](https://mise.jdx.dev).

## Prerequisites

- Linux (bwrap requires user namespaces)
- [zellij](https://zellij.dev) terminal multiplexer
- [mise](https://mise.jdx.dev) for tool version management
- [jq](https://jqlang.github.io/jq/) for JSON processing
- At least one of: [Claude Code](https://claude.ai/code), [Codex](https://github.com/openai/codex), [Pi](https://github.com/mariozechner/pi-coding-agent)

## Install

```bash
# Clone zcrew (once)
git clone https://github.com/DanielLukic/zcrew.git ~/zcrew

# Install into your project
~/zcrew/bin/zcrew install /path/to/your/project
cd /path/to/your/project
```

This copies `bin/zcrew`, `bin/bx`, agent launchers, the canonical cross-tool zcrew skill, tool-specific helper skills, root agent docs, sandbox config, and a managed mise floor into your project. Re-run to update.

**Global install (alternative):** if you prefer zcrew available in every project without per-project install, run `./install-globals.sh --include-zcrew` from the clone. This installs `bx`/`ix` to `~/.local/bin/` and deploys zcrew skills into the global config dirs of your agents (`~/.codex/skills/`, `~/.pi/agent/skills/`). Per-project install is still recommended for full control. *(DISCLAIMER: Not properly tested/used, yet!)*

## Quick start

Launch your orchestrator (Claude, Codex, or Pi) in the project root. The orchestrator reads the zcrew skill and knows how to spawn and manage agents. `AGENTS.md` is the committed root entrypoint; `CLAUDE.md` is a symlink to it for Claude-facing compatibility.

You can also spawn agents manually:

```bash
zcrew spawn claude claudio      # assistant / researcher
zcrew spawn codex sam           # reviewer
zcrew spawn pi piper            # implementer
```

The orchestrator handles `send`, `list`, `close`, `sync`, and `--compact` automatically. You steer it — tell it what to build, which agents to use, and it dispatches work to the team.

Available CLI commands for manual use: `zcrew spawn`, `send`, `close`, `list`, `sync`, `rename`.

## Components

| Tool | Purpose |
|------|---------|
| `bin/zcrew` | Multi-agent orchestration CLI |
| `bin/bx` | bwrap sandbox manager (lightweight, no container daemon) |
| `bin/ix` | Incus container manager (heavier, full apt, persistent) |
| `lib/zcrew/launchers/` | Per-agent launch scripts (claude.sh, codex.sh, pi.sh) |
| `.agents/skills/` | Canonical cross-tool skill location (`zcrew`) |
| `.claude/skills/` | Claude Code slash commands (/zspawn, /zsend, etc.) |
| `.pi/skills/` | Pi slash commands plus `zcrew` symlinked to `.agents/skills/zcrew` |
| `.codex/skills/` | Codex `zcrew` symlink to `.agents/skills/zcrew` |
| `AGENTS.md` / `CLAUDE.md` | Root agent docs; `CLAUDE.md` symlinks to `AGENTS.md` |

## Sandbox design

**bx** (bwrap) creates a per-project sandbox:
- Isolated HOME at `.bx/home/` (persistent across sessions)
- Host `/etc` mounted read-only
- Project dir mounted read-write
- Env vars scrubbed (LD_LIBRARY_PATH, HOMEBREW_*, DIRENV_*, etc.)
- Project `bin/` always first on PATH
- mise shims for tool resolution

## ix (Incus) — alternative sandbox *(DISCLAIMER: Not integrated, yet!)*

`bin/ix` provides a heavier alternative to bx using Incus/LXC containers. Full apt, persistent containers, UID-mapped shared mounts. Useful when agents need to install system packages or run long-lived services. Not part of the default zcrew workflow — bx covers most use cases.

### ix prerequisites

- [Incus](https://linuxcontainers.org/incus/) with your user in the `incus-admin` group
- A ZFS storage pool registered with Incus

### ZFS pool setup (example)

```bash
# Create a ZFS-backed storage pool (adjust path/size as needed)
sudo truncate -s 50G /path/to/incus-zfs.img
sudo zpool create mypool /path/to/incus-zfs.img

# Register with Incus
incus storage create incus-pool zfs source=mypool
```

### ix usage

```bash
ix setup       # create container, UID map, provision
ix run <cmd>   # run command inside container
ix shell       # interactive shell
ix stop        # stop container
```

Config lives in `.ix/config` per project (CONTAINER, IMAGE, WORKDIR). Optional `provision.sh` in `.ix/` runs at setup time for extra packages.

## Tests

```bash
bash tests/test-bx.sh      # 22 tests
bash tests/test-ix.sh      # 16 tests
bash tests/test-zcrew.sh   # 52+ tests
```

## License

[Unlicense](LICENSE) — public domain.
