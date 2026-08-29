# System Diagram — Container-First Dev Topology

```mermaid
flowchart TB
    subgraph HOST["HOST · Ubuntu 24.04"]
        direction TB
        subgraph UserSpace["hermes user · uid 1000"]
            HermesCfg["~/.hermes/<br/>plugins · skills · .env · Cognee · state.db"]
            DotCfg["~/.config/<br/>mise · yazi · herdr · starship"]
            LocalShare["~/.local/<br/>mise installs cache"]
            SshRO["~/.ssh/ :ro<br/>agent keys"]
            GitRO["~/.gitconfig :ro"]
            WsHost["~/workspace/"]
        end
        Sd["systemd --user<br/>hermes-gateway.service<br/>hermes-agent.service"]
        Dd["Docker daemon<br/>image: ghcr.io/you/dev-base:latest"]
    end

    subgraph Image["dev-base:latest image layers"]
        direction TB
        DevBase["dev-base · weekly rebuild<br/>mise · node/python/go/rust/ruby<br/>yazi · herdr · lazygit · fzf · fd · rg<br/>eza · bat · zoxide · starship · nvim · tmux<br/>build-essential · git · ssh"]
        Base["ubuntu:24.04 · CVE rebuild<br/>apt pkgs · ca-certs"]
        DevBase --> Base
    end

    subgraph Container["CONTAINER dev-sandbox · uid 1000:1000 · persistent"]
        direction TB
        subgraph HomeDev["/home/dev/"]
            MiseCfg[".config/mise :ro"]
            MiseInst[".local/share/mise :rw"]
            Yazi[".config/yazi :ro"]
            Herdr[".config/herdr :ro"]
            Cache[".cache :rw"]
            Git[".gitconfig :ro"]
            Ssh[".ssh :ro"]
        end
        Wd["/workspace/projects :rw<br/>bash · zsh · nvim · tmux<br/>yazi · lazygit · fzf · herdr"]
    end

    Dd -->|run| Image
    Image --> Container

    subgraph You["YOU · interactive"]
        direction TB
        Ssh["ssh → docker exec"]
        Panes["herdr panes<br/>yazi · claude<br/>nvim · kilo"]
        Ssh --> Panes
    end

    subgraph Hermes["HERMES AGENT"]
        direction TB
        Tb["terminal.backend=docker"]
        Bash["/bin/bash in container"]
        Tb --> Bash
    end

    You -->|shared workspace| Wd
    Hermes -->|shared workspace| Wd
```

## Key flows

- **Workspace** is the single shared filesystem between you and Hermes (`/home/hermes/workspace` on host → `/workspace/projects` in container).
- **Configs** flow host → container read-only so a container rebuild never loses your settings.
- **Caches** (mise installs, cargo, pnpm) flow host ← container read-write so installs survive recreation.
- **Hermes never sees `~/.hermes/` mounted into the sandbox** — Cognee and Kilo creds stay on the host, injected by Hermes itself.
- **You and Hermes share the same image and same UID**, so `pnpm install` and `cargo build` produce files you both own.

## Related

- Source analysis: `../convos/minimax-playbook-hermes.md`
- Coding rules: `coding-specs.md` Rule 1 (Mermaid for LLM-ingested markdown)