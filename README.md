# remote-dev

Skills repo for remote development tooling: devcontainers, dotfiles, and related infrastructure for the **Hermes stack** — a VPS system with a host plane that survives rebuilds, per-project containers for toolchains, and a knowledge plane the agent orchestrates (inbox → canon → graph).

## Repo layout

| Path | Purpose |
| --- | --- |
| `CONTEXT.md` | Domain language and knowledge for the Hermes stack (start here) |
| `host-plane/` | Host-plane config: Brewfile, mise.toml, systemd units (Herdr, Hermes dashboard, Buzz, cloudflared), compose files |
| `scripts/` | Install/provision/smoke scripts (bounce kit, Hermes dashboard, Buzz, cloudflared, relay maintenance) |
| `servers/` | Per-server notes and specs (e.g. `grr-buzz.md`, `grr-remote-dev-01.md`) |
| `docs/adr/` | Architecture decision records |
| `docs/agents/` | Guidance for coding agents: issue tracker, triage labels, domain docs |
| `research/` | Background research notes (Hermes API surface, Buzz self-host, web clients) |
| `references/` | Hardware/coding specs; `system-diagram.md` stub; archived rejected topology under `references/historical/` |
| `skills/` | **First-party in this repo:** `drain-inbox` only. `skills-lock.json` lists external Hermes Skills Hub / pack pins — those trees are **not** vendored here unless installed on the VPS. |
| `convos/` | Captured conversations / notes |

## Core concepts

- **Host plane** — the Ubuntu user session that survives container rebuilds: SSH, Docker Engine, Herdr, the bounce kit, mise, git, the Hermes process, `systemd --user`.
- **Project container** — a per-repo Dev Container holding that project's toolchain and services; rebuildable, not the daily mux.
- **Herdr** — the always-on terminal multiplexer on the host plane; the operator's normal coding path is remote attach from the laptop.
- **Hermes** — the Nous agent process (CLI, sessions, skills, profiles).
- **Buzz** — self-hosted Nostr collaboration workspace (Block) running as a host-plane service with a Cloudflare-public relay.
- **Agency tree** — `~/agency` on the host: canon (git wiki of sourced statements), inbox (raw captures), artifacts.
- **Secret store** — the laptop `pass` tree (GPG); `~/.hermes/.env` on the VPS is a checkout, not the original.

## Key decisions

See `docs/adr/` — notably:

- 0001: Herdr on host · 0003: host filesystem layout · 0007: `pass` is secret source · 0008: host-plane brew + chezmoi · 0012: keypair rotation and backup · 0013–0015: Buzz public hostname / relay sidecar / NIP-98 relay URL.

## For agents

Issue tracking happens in GitHub Issues; triage uses the five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, and `docs/agents/domain.md` before working in this repo.

## Provisioning

The `scripts/` directory is designed to run on a fresh Ubuntu VPS, roughly in this order:

1. `install-host-bounce-kit.sh` — bounce kit (fish, nvim, lazygit, yazi, fzf, …) via Homebrew on Linux
2. `install-hermes-dashboard.sh` — Hermes dashboard service
3. `install-buzz.sh` + `install-buzz-cloudflared.sh` — Buzz relay and public hostname
4. `provision-hermes-access.sh` / `enable-hermes-buzz.sh` / `smoke-buzz.sh` — access wiring and verification
