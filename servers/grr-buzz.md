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

SEE_FILE_REMAINDER