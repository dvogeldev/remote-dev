# Hermes stack

The VPS system being specified: a host plane that survives rebuilds, per-project containers for toolchains, and a knowledge plane the agent orchestrates (inbox → canon → graph).

## Language

### Execution

**Host plane**:
The Ubuntu user session that survives container rebuilds: SSH, Docker Engine, Herdr, the bounce kit, mise, git, the Hermes process, and systemd --user. Login shell is bash; fish is Herdr panes only.
_Avoid_: native, bare metal, VPS OS, the box (when you mean this session, not the machine); chsh to fish

**mise**:
Host-plane version manager for operator Node and Python (`host-plane/mise.toml`). Project containers still have their own mise for that repo’s toolchain.
_Avoid_: copying the laptop mise.toml onto the VPS; apt Node as the project toolchain; treating host mise as a replacement for Dev Containers

**Bounce kit**:
Host-plane interactive CLI used in Herdr panes: fish, zoxide, eza, bat, ripgrep, fd, Neovim, lazygit, yazi, fzf. Packaged with Homebrew on Linux. Live configs are `/home/david/.config` on the VPS.
_Avoid_: treating this as the project-container tool list (#8); Distrobox/Alpine tool containers; Devbox shells; apt as the source of current nvim/yazi

**Homebrew on Linux**:
Package source for the bounce kit on the host plane. Prefix `/home/linuxbrew/.linuxbrew`. Not on the Omarchy laptop.
_Avoid_: Linuxbrew as a separate product; brew on the laptop; Nix or home-manager; deb.griffo.io on the host; `brew install herdr` (Herdr stays `install.sh` + systemd)

**User lane**:
Chezmoi-managed operator configs (fish, nvim, yazi, lazygit, herdr). One repo, two machines; the VPS apply skips the Omarchy desktop.
_Avoid_: home-manager as the writer; copying or mounting the laptop home; applying Hypr/browsers/espanso/`pass` onto the VPS

**Project container**:
A per-repo Dev Container that holds that project's toolchain and services. Rebuildable. Not the daily mux.
_Avoid_: sandbox (that word is Hermes' terminal backend), dev-base (the rejected shared-image desktop), image (too generic)

**Herdr**:
The always-on terminal multiplexer on the host plane, attached with `herdr --remote` or SSH-then-`herdr`.
_Avoid_: tmux; Herdr inside a project container as the default

**Hermes**:
The Nous agent process (CLI, sessions, skills, profiles). The desk, not the library.
_Avoid_: the stack, the VPS, the model

**Hermes dashboard**:
The shipped browser UI for managing Hermes: profiles, config, API keys, models, skills, MCP, sessions, analytics, logs, cron jobs, and a Chat tab that drives the real Hermes TUI over an authenticated PTY/WebSocket. Started by `hermes dashboard` on `127.0.0.1:9119` by default. Fail-closed on non-loopback binds (requires password / Nous OAuth / OIDC since the June 2026 hardening). This is the surface "Hermes GUI" maps to; do not build greenfield when the dashboard already covers it.
_Avoid_: Hermes Web UI (the dashboard's product name); admin panel; management UI (too generic); a separate custom GUI project on top of `gateway:8642` for configs

**Buzz (Block, Apache-2.0)**:
A self-hostable Nostr-based collaboration workspace for humans and AI agents from Block, released 2026-07-21. A downstream concept in this stack: a possible future Hermes messaging-gateway channel like Telegram / Discord / Slack. Has its own cryptographic identity model per actor (Nostr keypairs) and does NOT replace the Hermes dashboard; the dashboard is the operator surface over Hermes, Buzz is the multi-actor collaboration plane that may one day have Hermes plugged in.
_Avoid_: confusing Buzz with the Hermes GUI; treating Buzz as the Hermes dashboard's successor

**Profile**:
A whole Hermes agent identity (SOUL, skills, sessions, memory). Named for a **role**, not a model. Day one there is only `default` (operator). Further roles are cloned when that role has a skill.
_Avoid_: `hermes-m27` / model SKUs as profile names; `--clone-all` for new roles

**Hermes stack**:
This whole specified system (host plane + project containers + Hermes + knowledge plane).
_Avoid_: playbook (a document), minimax stack (inference only)

**Remote attach**:
The operator's normal coding path: a Herdr client on the laptop attached to Herdr on the host plane (nvim on the host; toolchain commands via `devcontainer exec` in panes).
_Avoid_: docker exec as the daily desktop; living inside a project container; SSH-then-fish as the primary coding path

**Agency tree**:
`~/agency` on the host plane: canon, inbox, and artifacts. Only canon is a git repo.
_Avoid_: putting canon under `~/projects`; one git repo over the whole agency tree

**Projects tree**:
`~/projects/<repo>` on the host plane: coding checkouts, each with its own project container.
_Avoid_: `~/workspace` (playbook name, not the human path)

**Hermes shell**:
Where the agent's terminal and file tools run: the host-plane user (`terminal.backend: local`).
_Avoid_: Hermes-in-Docker (the official image); a generic Docker sandbox as the daily shell

**Secret store**:
The laptop `pass` tree (GPG). `~/.hermes/.env` on the VPS is a checkout, not the original.
_Avoid_: Cloudflare Secrets Store for Hermes; `pass` on the VPS as the daily path

### Knowledge

**Memory provider slot**:
Hermes' single optional external MemoryProvider. Empty in this stack (`hermes memory off`).
_Avoid_: Cognee as provider; filling the slot to be safe

**Canon**:
The git wiki of promoted, sourced statements. The library; source of truth.
_Avoid_: Open Brain, session memory, the graph, inbox

**Inbox**:
`~/agency/inbox/` — raw file captures not yet promoted. The loading dock this phase.
_Avoid_: Open Brain as the dock; using the inbox as canon or a task list

**Open Brain**:
Existing Supabase thought store, used as a **read** resource over MCP when a wiki page or workflow needs extra context. Not the dock, not the MemoryProvider, not the wiki.
_Avoid_: draining Open Brain as inbox; `hermes memory setup` for Open Brain; auto-hosing every inbox file into it this phase

**Graph**:
Cognee over promoted canon and finished artifacts only.
_Avoid_: session transcript dump; using Cognee as the memory provider slot
