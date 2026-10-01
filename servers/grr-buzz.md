# Buzz relay on grr-remote-dev-01 — runbook

Resolves [#47](https://github.com/dvogeldev/remote-dev/issues/47). Parent: [#36](https://github.com/dvogeldev/remote-dev/issues/36).

## What this gives you

- A self-hosted Block Buzz relay running as a Docker Compose stack on `grr-remote-dev-01`, bound to `127.0.0.1:3000`. Loopback-only: no public port, no public hostname in v0.
- Postgres 17, Redis 7, MinIO, a git-volume, and a `buzz-pair-relay` sidecar (loopback `:5000`) behind the relay, all in one Compose project (`buzz-prod`).
- Hermes (the agent) reaches the relay at `ws://127.0.0.1:3000` from the same host — no extra networking required.
- Operator reaches the Buzz desktop client from the laptop via Tailscale or an SSH tunnel.

## Decisions locked

| | |
|---|---|
| Compose artifact | Vendored at `host-plane/buzz-compose.yml` (Apache-2.0 from upstream `block/buzz/deploy/compose/compose.yml`; host-plane adds loopback binds + `pair` sidecar, ADR #0014) |
| Install location on grr | `~/.buzz/{compose.yml,.env}` |
| Env file mode | `0600` (laptop push only, never world-readable) |
| Service unit | `~/.config/systemd/user/buzz.service` (Type=simple, ExecStart=docker compose up). The unit is the control plane: `systemctl --user start|stop|restart buzz.service`. |
| Image pin (v0) | `ghcr.io/block/buzz:main` (pin to `:sha-<7>` before declaring v0 done — `relay-v*` tags are not yet published to GHCR as of writing) |
| Relay keypair | laptop `pass buzz/relay/private-key` (nsec line 1, npub line 2) → `BUZZ_RELAY_PRIVATE_KEY` in `~/.buzz/.env` |
| Backing-service secrets | Generated on grr by `install-buzz.sh` (Postgres, Redis, MinIO, HMAC); live in `~/.buzz/.env` |
| Relay policy | `BUZZ_REQUIRE_AUTH_TOKEN=true`, `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`, `BUZZ_ALLOW_NIP_OA_AUTH=true`, `BUZZ_AUTO_MIGRATE=true` |
| Surface | Loopback-only (`127.0.0.1:3000`). Cloudflared-fronted is deferred — see Out of scope. |
| **BUZZ_DOMAIN** | **MUST be set to `127.0.0.1`** (v0 loopback) so the relay's host→community resolver accepts WS connections with `Host: 127.0.0.1:3000`. The default (unset) makes the relay refuse every WS handshake with `404 no community is configured for this host`. See "Gotcha" below. |

ADR: [0011-buzz-host-plane-layout.md](../docs/adr/0011-buzz-host-plane-layout.md).

### Ops note: pin Buzz image off `:main` before calling v0 done

v0 still pulls `ghcr.io/block/buzz:main` (see Decisions locked). That floating tag is fine while iterating; **before declaring v0 done**, pin the relay (and any sibling services that share the same tag) to a digest or `:sha-<7>` once a known-good image is verified:

1. On grr after a successful smoke: `cd ~/.buzz && docker compose images` — record the relay image ID / RepoDigest.
2. Edit `~/.buzz/compose.yml` (and keep `host-plane/buzz-compose.yml` in this repo in sync) so `image:` uses `ghcr.io/block/buzz@sha256:…` or `:sha-<7>` — not `:main`.
3. Re-run `HOST=grr ./scripts/smoke-buzz.sh`.
4. Prefer a published `relay-v*` GHCR tag when upstream ships one; until then digest/`sha-` pin is the ops bar.

Do **not** open a new ADR for this — the Decisions locked row already calls out the TODO. This section is the runbook.


### Gotcha: BUZZ_DOMAIN and the host→community resolver

The relay uses the WS upgrade's `Host` header to resolve which "community"
the connection targets. Single-community mode is the self-host default, but
the relay still needs `BUZZ_DOMAIN` set to recognise any host as its own —
otherwise every connection gets `404 no community is configured for this
host`. For v0 loopback-only:

```
BUZZ_DOMAIN=127.0.0.1
RELAY_URL=ws://127.0.0.1:3000
BUZZ_MEDIA_BASE_URL=http://127.0.0.1:3000/media
BUZZ_MEDIA_SERVER_DOMAIN=127.0.0.1
BUZZ_CORS_ORIGINS=http://127.0.0.1:3000
```

Implications for the operator:

- **Hermes** (running on grr) connects to `ws://127.0.0.1:3000` — Host header
  `127.0.0.1:3000`, matches `BUZZ_DOMAIN=127.0.0.1`. ✓
- **Operator via SSH tunnel** uses `ssh -L 3000:127.0.0.1:3000 grr`, then
  points the Buzz desktop client at `ws://127.0.0.1:3000`. The Host header
  will be `127.0.0.1:3000` — matches. ✓
- **Operator via Tailscale** (`ws://grr-remote-dev-01:3000`) sends Host
  `grr-remote-dev-01:3000` — does **not** match `BUZZ_DOMAIN=127.0.0.1`.
  The `127.0.0.1 grr-remote-dev-01` `/etc/hosts` workaround was used during
  v0; it has been retired in favor of the **public-hostname path** below.
  For loopback-only mode, run the relay in multi-community mode (deferred)
  or use the SSH tunnel.

The install script sets `BUZZ_DOMAIN=127.0.0.1` automatically when
`BUZZ_PUBLIC_HOSTNAME` is unset; the smoke test verifies the relay accepts
connections with that Host header.

### Public hostname path (`buzz.dvogeldev.com`, #53)

When `BUZZ_PUBLIC_HOSTNAME` is set in `~/.buzz/.env`, `install-buzz.sh`
Stage 4b rewrites the client-facing URLs (`BUZZ_MEDIA_BASE_URL`,
`BUZZ_MEDIA_SERVER_DOMAIN`, `BUZZ_CORS_ORIGINS`) to use the public
hostname. `BUZZ_DOMAIN` and `RELAY_URL` stay loopback — the relay's
host→community resolver matches `Host: 127.0.0.1:3000`, and `cloudflared`
rewrites the incoming `Host: buzz.dvogeldev.com` back to that loopback value
via `originRequest.httpHostHeader`. Mobile clients, a second operator on a
different tailnet, and cross-device workflows all work without Tailscale or
SSH tunnels.

See `servers/buzz-dvogeldev-access.md` for the full runbook (CF Access app,
tunnel token issuance, rate-limit rules, smoke-test extension). ADR
[0013](../docs/adr/0013-buzz-public-hostname-via-cloudflare.md) locks the
two-tunnel shape and the Host-header rewrite.

## Day-one procedure

### Phase 1 — Install (AFK from the laptop)

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/install-buzz.sh         # Buzz relay on grr
HOST=grr ./scripts/enable-hermes-buzz.sh   # Hermes gateway → buzz plugin enabled
```

Two scripts, both laptop-driven via SSH to grr.

**`install-buzz.sh`** lays down `~/.buzz/{compose.yml,.env.example}`, the
systemd user unit `~/.config/systemd/user/buzz.service`, enables linger
for `david` on grr, generates the relay keypair (via `nak key generate`,
stores in `pass buzz/relay/private-key`), generates backing-service
secrets, sets `BUZZ_DOMAIN=127.0.0.1` and related URLs, and prompts you
to set `RELAY_OWNER_PUBKEY` in `~/.buzz/.env` before continuing.

**`enable-hermes-buzz.sh`** deploys a small Python shim at
`~/.local/bin/buzz` (see `host-plane/buzz-shim/buzz`) that satisfies the
plugin's hard-fail on `buzz` CLI absence — see "Why a buzz shim" below.
It then writes `BUZZ_RELAY_URL`, `BUZZ_TRANSPORT`, `BUZZ_HOME_CHANNEL`,
`BUZZ_CHANNELS`, `BUZZ_ALLOWED_USERS`, `BUZZ_CLI_PATH` into
`~/.hermes/.env` (Hermes's keypair was already there per #46), sets
`gateway.platforms.buzz.enabled: true` in `~/.hermes/config.yaml`, runs
`hermes gateway install` to create `hermes-gateway.service`, and starts
it.

If `install-buzz.sh` stops at the `RELAY_OWNER_PUBKEY` gate:

```bash
ssh grr '$EDITOR ~/.buzz/.env'         # set RELAY_OWNER_PUBKEY=<operator-hex>
HOST=grr ./scripts/install-buzz.sh     # resumes: pull + start unit + healthcheck wait
HOST=grr ./scripts/enable-hermes-buzz.sh  # then enable Hermes's buzz plugin
```

The end state: `buzz.service` AND `hermes-gateway.service` both active,
`docker compose ps` shows all five containers healthy, and
`~/.hermes/logs/gateway.log` shows `✓ buzz connected`.

### Why a buzz shim (not `buzz-cli` from source)

The bundled Hermes `buzz` plugin's `connect()` hard-fails if `BUZZ_CLI_PATH`
(or `buzz` on PATH) is missing — regardless of `BUZZ_TRANSPORT`. The real
`buzz-cli` is a Rust crate shipped from `block/buzz` (not in the relay
image; not a standalone GitHub release); building it from source on grr
requires installing Rust + cloning the repo + ~10 minutes of compile
time, which is a poor trade for a v0 inbound-only demo.

The shim at `host-plane/buzz-shim/buzz` implements the minimum CLI
surface the plugin needs (`users get`, `channels list`, `messages get`,
`dms list`, `version`) with the same JSON contracts as the real
`buzz-cli`. Inbound via WebSocket works without the real CLI. **Outbound
sends** (Hermes → Buzz) fail with a JSON error on stderr — for v0
inbound demo that's fine; for Hermes to reply in #49, the operator
builds the real CLI:

```bash
ssh grr
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. "$HOME/.cargo/env"
cargo install --git https://github.com/block/buzz --bin buzz-cli --locked
install -m 0755 "$HOME/.cargo/bin/buzz-cli" /usr/local/bin/buzz
rm ~/.local/bin/buzz   # the shim becomes obsolete
systemctl --user restart hermes-gateway.service
```

### Phase 2 — Admin bootstrap (HITL, do these in order on grr)

**2.1 Confirm Hermes's pubkey is on the VPS.**

```bash
ssh grr 'cat ~/.hermes/nostr.npub'
```

If empty, run `scripts/unwrap-hermes-env.sh` from the laptop first (this
unwraps `nostr/hermes-buzz/private-key` from pass into `~/.hermes/.env` and
