# grr-remote-dev-01

## Specs

| Property       | Value                |
|----------------|----------------------|
| Hostname       | grr-remote-dev-01    |
| OS             | Ubuntu 24.04 LTS (Noble Numbat) |
| Provider       | RackGenius           |
| Location       | Grand Rapids, MI     |
| CPU            | TBD                  |
| RAM            | TBD                  |
| Disk           | TBD                  |
| Swap           | 1 GB                 |
| SSH Key        | Rackgenius           |

## Network

| Property | Value         |
|----------|---------------|
| IPv4     | 163.123.236.73 |
| IPv6     | 2602:f964:1:7a::a |
| Tailscale IPv4 | 100.80.237.36 |
| Tailscale IPv6 | fd7a:115c:a1e0::cf3a:ed25 |
| MagicDNS | grr-remote-dev-01.tail6acbf0.ts.net |
| SSH Port | 22            |
| DNS Resolvers | 1.1.1.1, 8.8.8.8 |
| Tailscale SSH | off (use sshd) |

## Access

| Property | Value         |
|----------|---------------|
| User     | david (uid 1000; sudo, docker) |
| SSH Keys | `~/.ssh/rack_genius01` (Host `grr` / `grr-remote-dev-01`) |

## Host paths

| Path | Role |
|------|------|
| `~/agency` | Knowledge plane (inbox → canon → artifacts); only canon is git |
| `~/projects` | Coding checkouts; each repo may use its own Dev Container |
| `~/.hermes` | Nous Hermes Agent config / `.env` checkout (see ADR-0007) |
| `~/.buzz` | Buzz compose + env (see `grr-buzz.md`) |

## Services (index)

- **Host plane:** Herdr + bounce kit (Homebrew/Linux) + host `mise` — ADR-0001, ADR-0008; `host-plane/`
- **Nous Hermes Agent:** process on host; `terminal.backend: local` (ADR-0004); dashboard loopback `:9119` + CF Access — [`hermes-dvogeldev-access.md`](hermes-dvogeldev-access.md)
- **Buzz:** Compose on host; public `buzz.dvogeldev.com` via separate tunnel — [`grr-buzz.md`](grr-buzz.md), [`buzz-dvogeldev-access.md`](buzz-dvogeldev-access.md)
- **Secrets:** laptop `pass` → `~/.hermes/.env` via `scripts/unwrap-hermes-env.sh` (ADR-0007); do not install `pass` on the VPS
- **Project toolchains:** per-repo Dev Containers under `~/projects` — **not** the rejected shared `dev-base` desktop (see archived diagram)

## Capacity note

Fill CPU/RAM/disk above when known. Community Hermes guidance often cites ~1 GB minimum / ~2–4 GB comfortable when containers are involved; this host also runs Buzz (Postgres/Redis/MinIO) beside local Hermes shell.

## Related

- Domain language: [`CONTEXT.md`](../CONTEXT.md)
- Current diagram: [`../references/system-diagram.md`](../references/system-diagram.md)
- Ops checklist: [`../docs/agents/hermes-ops-checklist.md`](../docs/agents/hermes-ops-checklist.md)
- Archived rejected topology: [`../references/historical/system-diagram-container-first.md`](../references/historical/system-diagram-container-first.md)
