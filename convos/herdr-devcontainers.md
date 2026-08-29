The setup that fits Herdr + Neovim best is: **treat the VPS as the always-on Herdr host, and treat Dev Containers as per-project toolchains that Herdr panes exec into.** Do not try to recreate the VS Code “Reopen in Container” loop.

Herdr is already a remote-first multiplexer. Its two supported remote modes are SSH-then-`herdr`, or `herdr --remote <host>` as a thin local client. That maps cleanly onto a rented Ubuntu box. Dev Containers then give each repo its own compiler, runtime, and services without forcing you through a VS Code remote window.

## Architecture

```
laptop terminal
    herdr --remote vps          # or: ssh vps && herdr
        │
        ▼
Ubuntu VPS  (Docker + herdr server, always running)
    workspace: project-a
        pane: nvim              # edits bind-mounted files
        pane: claude / tests    # runs *inside* the project container
        pane: app / db logs
    workspace: project-b
        ...
```

Why this split:

- Herdr’s value is persistence across disconnects. That belongs on the VPS host, not inside a container that you rebuild.
- Dev Containers’ value is isolated toolchains. That belongs per project.
- Neovim + Herdr plugins (`herdr-nvim`, pane navigation) expect Neovim to be a **Herdr pane**, so run `nvim` on the host session, not as a detached process inside Docker.

If you instead run Herdr *inside* every container, rebuilds kill agent sessions and `herdr --remote` has to target a different SSH port per project. That is workable, but worse for a daily remote box.

## 1. VPS baseline

On a fresh Ubuntu 24.04 box:

- Non-root user with SSH keys only, `ufw` allowing SSH (and Tailscale if you use it).
- Docker Engine from Docker’s repo, user in the `docker` group. Not Docker Desktop.
- Host tools: `git`, `ripgrep`, `fd`, `fzf`, Neovim, Herdr.
- Official Dev Container CLI on the host:

```bash
# node is only needed for the CLI
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g @devcontainers/cli
```

Layout:

```text
~/projects/app-a/.devcontainer/devcontainer.json
~/projects/app-b/.devcontainer/devcontainer.json
```

SSH config on the laptop:

```sshconfig
Host vps
  HostName your.vps.example
  User you
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent yes
  ControlMaster auto
  ControlPersist 10m
```

Daily attach:

```bash
herdr --remote vps
# or named session:
herdr --remote vps --session agents
```

`herdr --remote` bootstraps a matching Herdr binary on the VPS if needed and streams the UI to your local terminal. Use plain `ssh vps` then `herdr` from a phone or when you want tmux-style “everything is remote.”

## 2. Per-project Dev Container

Keep `devcontainer.json` about the **project**, not about your editor. Language image + features + lifecycle hooks. Example:

```json
{
  "name": "app-a",
  "image": "mcr.microsoft.com/devcontainers/python:3.12",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {},
    "ghcr.io/devcontainers/features/git:1": {}
  },
  "forwardPorts": [8000],
  "remoteUser": "vscode",
  "postCreateCommand": "pip install -e '.[dev]'",
  "runArgs": ["--name", "dev-app-a"]
}
```

On the VPS, from the repo root:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

The CLI bind-mounts the project into the container. That is the important part: **Neovim on the host and processes in the container see the same files.**

Small host helpers keep Herdr panes short:

```bash
# ~/bin/dc
#!/usr/bin/env bash
set -euo pipefail
root=$(git -C "${1:-.}" rev-parse --show-toplevel)
cmd=${2:-bash}
shift 2 || true
devcontainer exec --workspace-folder "$root" "$cmd" "$@"
```

Then a Herdr pane is just `dc ~/projects/app-a claude` or `dc ~/projects/app-a pytest`.

Give containers names (`runArgs: ["--name", "dev-app-a"]`) and resource limits if the VPS is shared across several stacks. Use Compose in `devcontainer.json` when a project needs Postgres/Redis rather than stuffing services into the same image.

## 3. Neovim in this setup

Run Neovim **in a Herdr pane on the VPS**, opened on the host checkout:

```bash
cd ~/projects/app-a
nvim
```

That keeps `herdr-nvim`, `vim-herdr-navigation`, and agent-annotation plugins working, because they need Herdr’s pane env (`HERDR_PANE_ID`, socket path).

For LSP / formatters / test runners that must match the container:

- Point the LSP `cmd` at `devcontainer exec` / `docker exec`, or
- Install the language server in the image and use a one-line wrapper:

```bash
#!/usr/bin/env bash
exec devcontainer exec --workspace-folder "$HOME/projects/app-a" pyright-langserver --stdio
```

Do **not** bind-mount your entire `~/.config/nvim` into every container unless you also pin plugin/mason artifacts. Host nvim + container toolchain is less fragile.

Dotfiles that belong in the container (gitconfig, language version managers) go through `postCreateCommand` or a private dotfiles repo referenced by the spec. Editor config stays on the VPS home directory.

## 4. Day-to-day loop

1. `herdr --remote vps`
2. One Herdr workspace per repo.
3. First pane: `nvim` on the host tree.
4. Other panes: `devcontainer exec` for agents, servers, tests.
5. Detach with `prefix+q`. Agents keep running on the VPS. Reattach later from laptop or phone.

Bring a container up once after clone/rebuild; leave it running. `devcontainer up` is idempotent enough for that.

## When to choose a different shape

**Herdr inside the container** if a project must be fully sealed (different OS user, no host Node/Python at all, untrusted deps). Add `ghcr.io/devcontainers/features/sshd:1`, publish a unique host port per project, put that host in `~/.ssh/config`, then `herdr --remote app-a-container`. Install Herdr + Neovim + `socat` in the image. Rebuilds reset that Herdr server unless you persist its state directory.

**DevPod SSH provider on the VPS** if you want `devcontainer.json` orchestration without driving the CLI yourself. DevPod gives you an SSH target per workspace; you still attach Herdr to that target. `remote-nvim.nvim` also uses DevPod if you ever want a local Neovim UI talking to a remote server — usually unnecessary if Herdr is already your UI.

**Skip Dev Containers** if isolation is only “different Node versions.” `mise` or Nix on the VPS plus Herdr workspaces is simpler and faster. Use containers when dependencies, system libs, or sidecar services actually differ.

## Details that usually bite people

- File ownership: keep `remoteUser` consistent and avoid editing as root in the container, or the host tree gets root-owned files.
- Docker socket: only mount it (`docker-outside-of-docker`) if the project must start sibling containers. That weakens isolation.
- Ports: publish or forward per project (`8000`, `8001`, …) or put the VPS on Tailscale and bind services to the tailnet address.
- Secrets: keep `.env` on the VPS, not in the image. Mount or copy in `postStartCommand`.
- Backups: back up `~/projects` and Herdr session state; containers are disposable.
- Phone access: `ssh vps` then `herdr`. Do not rely on `herdr --remote` from a constrained mobile SSH client.

The method that stays out of your way is: **one Herdr server on the Ubuntu VPS, one Dev Container per project, Neovim as a host pane, project commands via `devcontainer exec`.** That uses each tool for what it is good at and avoids pretending Herdr is VS Code.

Use the VPS as a **tailnet-only machine**. Nothing on `0.0.0.0` except what you deliberately publish for a website or a preview. SSH, Herdr, Docker, Playwright, and app ports stay on the Tailscale interface.

## Target shape

```
laptop (Tailscale)
    herdr --remote vps          # MagicDNS, no public :22
        │
        ▼
Ubuntu VPS
    tailscale0  100.x.y.z       # only NIC that accepts SSH / Herdr / previews
    eth0        public IP       # UFW default deny
        docker
          dev-app-a   ports bound to 100.x.y.z or localhost
          playwright  no published ports
```

Public listeners: none, or only `80/443` if you really need a public site. Prefer Tailscale Serve/Funnel over opening Docker ports on the WAN NIC.

## 1. Lock the public firewall first

On the VPS, after Tailscale is up and you can reach it from the laptop:

```bash
sudo tailscale up --ssh --accept-dns=false
sudo tailscale set --ssh
```

`--ssh` is the important part: you can drop public port 22 and use Tailscale SSH (identity from your tailnet, not a hole in `sshd`). Keep classic `sshd` bound only to the tailnet if you still want `herdr --remote` over normal OpenSSH.

```bash
# /etc/ssh/sshd_config.d/tailscale.conf
ListenAddress 100.x.y.z
PasswordAuthentication no
PubkeyAuthentication yes
```

UFW:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
# only if you need a real public website:
# sudo ufw allow 80/tcp
# sudo ufw allow 443/tcp
sudo ufw enable
```

Do **not** `ufw allow 22`. Confirm from a network that is not the tailnet that `22` and Docker ports are closed.

Disable Docker’s habit of punching the host firewall:

```bash
# /etc/docker/daemon.json
{
  "iptables": true,
  "ip6tables": true,
  "userland-proxy": false
}
```

And never publish as `0.0.0.0:8000`. Use the tailnet IP or loopback.

## 2. Reach Herdr only over the tailnet

Laptop `~/.ssh/config`:

```sshconfig
Host vps
  HostName vps.tailnet-name.ts.net
  User you
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent yes
```

Daily:

```bash
herdr --remote vps
```

Herdr’s remote client is just SSH. MagicDNS is enough; no extra Herdr port, no public listener. Phone path is the same: Tailscale app + SSH + `herdr`.

If you use Tailscale SSH only (no `sshd` on the box), test `ssh vps` first. `herdr --remote` needs a working OpenSSH-style session; Tailscale SSH usually works as that transport. If a client is picky, leave `sshd` listening on `100.x.y.z:22` only.

## 3. Dev Containers with no public ports

In `devcontainer.json`, do not use `"appPort": ["8000"]` in a way that publishes to all interfaces. Prefer:

```json
{
  "runArgs": [
    "--name", "dev-app-a",
    "--publish", "100.x.y.z:8000:8000"
  ]
}
```

Or publish nothing and use Tailscale Serve from the host:

```bash
# app listens on 127.0.0.1:8000 inside the container,
# mapped to host loopback
devcontainer up --workspace-folder .

sudo tailscale serve --bg 8000
# https://vps.tailnet-name.ts.net  (tailnet only)
```

- **Tailnet preview:** `tailscale serve`
- **Public preview:** `tailscale funnel` (still no extra raw port on Docker; Funnel fronts 443)
- **Playwright:** no serve, no funnel, no publish

Playwright should run *inside* the project container on the VPS. Headless Chrome talks to `localhost` in that network namespace. You do not expose `9323` / CDP unless you are remote-debugging from the laptop; if you must, bind that port to `100.x.y.z` only and open it from the laptop over the tailnet.

```json
{
  "runArgs": ["--name", "dev-app-a"],
  "forwardPorts": [],
  "remoteEnv": {
    "PLAYWRIGHT_BROWSERS_PATH": "/ms-playwright"
  }
}
```

Install browsers in the image (`npx playwright install --with-deps`). Traces and HTML reports are files on the bind-mounted repo; open them on the laptop via `scp` or `tailscale file`, or `python -m http.server` bound to the tailnet IP if you want a clickable report.

## 4. Herdr panes that stay isolated

Host Herdr, container toolchains, as before — but every process that listens binds to loopback or `tailscale0`.

```bash
# pane: editor on host tree
nvim

# pane: tests / agents inside the container (no ports)
devcontainer exec --workspace-folder ~/projects/app-a playwright test

# pane: web app
devcontainer exec --workspace-folder ~/projects/app-a \
  env HOST=127.0.0.1 PORT=8000 npm run dev
```

Then `tailscale serve 8000` on the VPS, or browse `http://100.x.y.z:8000` from a laptop that is on the tailnet.

## 5. Checklist so you do not leak ports

| Service | Bind | Public UFW |
|---|---|---|
| `sshd` | `100.x.y.z:22` or Tailscale SSH only | closed |
| Herdr | unix socket on VPS, SSH-wrapped | closed |
| Docker Engine | unix socket | closed |
| App preview | `127.0.0.1` + Serve, or `100.x.y.z` | closed |
| Public site | Serve/Funnel or `:80/:443` only | 80/443 only if needed |
| Playwright | container localhost | closed |
| CDP / debug | `100.x.y.z` only, temporary | closed |

Verify from outside the tailnet:

```bash
nmap -Pn your.public.ip
```

You should see nothing (or only 80/443). From the laptop on Tailscale you should see SSH and whatever you served.

That is the whole change from the previous design: **same Herdr + Dev Container layout, transport is Tailscale, Docker never publishes to the WAN.**
