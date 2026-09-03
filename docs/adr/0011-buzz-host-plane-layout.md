# Buzz host-plane layout on `grr-remote-dev-01`

Status: **Accepted** for v0 of [#36](https://github.com/dvogeldev/remote-dev/issues/36).
Resolves [#47](https://github.com/dvogeldev/remote-dev/issues/47).

## Context

[#36](https://github.com/dvogeldev/remote-dev/issues/36) needs a self-hosted
Buzz instance running on the host plane, behind the same access model as
`hermes-dashboard` (loopback bind + Tailscale / SSH tunnel; no public port).
[#38](https://github.com/dvogeldev/remote-dev/issues/38) established that
Block's `deploy/compose/` bundle is the right artifact: it ships a working
`compose.yml`, an `.env.example`, a `run.sh` wrapper, and a Caddy override for
TLS. The map says "loopback-only or cloudflared-fronted" and to follow the
`hermes-dashboard` pattern.

The host-plane conventions in this repo (from
[ADR-0007](../0007-pass-is-secret-source.md), [ADR-0009](../0009-hermes-nostr-identity-location.md),
[ADR-0010](../0010-hermes-nostr-custody-workflow.md)) are:

- Production secrets live in laptop `pass`; the VPS only ever sees mode-0600
  checkouts via scripts under `scripts/`.
- Service configuration is committed at `host-plane/<name>.{service,*.example}`;
  install scripts in `scripts/install-<name>.sh` are the AFK entry point and
  SSH onto the host.
- Runbooks for HITL operator actions live in `servers/<host>.md`.
- The hermes-dashboard pattern (systemd --user unit, loopback bind, public
  hostname optional via cloudflared) is the proven shape.

## Decision

Compose, secrets, and surface for Buzz on `grr-remote-dev-01`:

1. **Compose file** lives at `~/.buzz/compose.yml` on the VPS, vendored from
   [`block/buzz@main/deploy/compose/compose.yml`](https://github.com/block/buzz/blob/main/deploy/compose/compose.yml).
   Tracked in this repo at `host-plane/buzz-compose.yml` so updates are
   diff-able. The only structural changes vs upstream: the relay binds
   `127.0.0.1:3000` on the host (no public port) and backing-service image
   tags are pinned to the exact versions upstream ships today.

2. **Env file** lives at `~/.buzz/.env` (mode 0600), seeded from
   `host-plane/buzz/.env.example`. `scripts/install-buzz.sh` generates fresh
   `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `BUZZ_S3_ACCESS_KEY`,
   `BUZZ_S3_SECRET_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET` on first run and writes
   them into `.env` in place. The relay keypair
   (`BUZZ_RELAY_PRIVATE_KEY`) is generated on the laptop via `nak key
   generate`, stored in `pass buzz/relay/private-key` (nsec + npub, two
   lines), and pushed into `~/.buzz/.env` over SSH. This matches ADR-0007.

3. **Image pin**: default `BUZZ_IMAGE=ghcr.io/block/buzz:main`. The research
   file `research/buzz-selfhost.md` recommended `relay-v*`, but at the time
   of writing those tags are NOT published to GHCR (only `:main`, `:latest`,
   and `:sha-<7>` rolling tags are). For v0 demo `:main` is acceptable per
   upstream's own "early testing" guidance; pin to `:sha-<7>` (or a future
   `relay-v*`) before declaring v0 done.

4. **Service unit** lives at `~/.config/systemd/user/buzz.service`,
   `Type=simple`, `ExecStart=docker compose up`. Compose runs in the
   foreground under systemd so the unit's status reflects stack health; the
   relay container itself has `restart: unless-stopped` so a single crash
   recovers without the unit restarting. `Restart=no` on the unit so the
   operator decides when to bring the stack back.

5. **Loopback-only** is the v0 surface. Hermes (the agent) reaches the relay
   at `ws://127.0.0.1:3000` from the same host — no extra networking
   required. The operator reaches the Buzz desktop client over Tailscale or
   an SSH tunnel. `cloudflared`-fronted exposure is deferred (and a future
   ADR if it ever happens); for v0 the rate-limit gap documented in research
   is mitigated by the loopback-only bind.

6. **`BUZZ_DOMAIN=127.0.0.1`** must be set even in single-community mode
   (the default). Without it, the relay refuses every WS upgrade with
   `404 no community is configured for this host` because the host→community
   resolver can't recognise any Host header as its own. Setting it to
   `127.0.0.1` matches the loopback bind and makes the relay accept
   `Host: 127.0.0.1:3000` connections from Hermes and from the operator's
   SSH-tunneled Buzz desktop client. Tailscale users need an `/etc/hosts`
   alias on the laptop until multi-community mode (deferred) lands.

7. **Membership** is created out of band: the operator runs
   `docker compose exec relay buzz-admin add-member --pubkey <hex> --role
   bot <hermes-hex-pubkey>` after Hermes's pubkey is on the VPS per [#46].
   This matches the v0 single-key model and the room-semantics decision in
   [#43](https://github.com/dvogeldev/remote-dev/issues/43).

8. **Room wiring** uses the Buzz desktop client (HITL). Operator creates the
   demo room in the UI, copies its UUID into `BUZZ_HOME_CHANNEL` and
   `BUZZ_CHANNELS` in `~/.hermes/.env` (managed by
   `scripts/unwrap-hermes-env.sh` per ADR-0010), then restarts the Hermes
   gateway.

## Consequences

- **`~/.buzz/.env` is load-bearing** — losing `BUZZ_RELAY_PRIVATE_KEY`
  breaks every past relay-signed event; losing the backing-service passwords
  makes the volumes unreadable. Backed up as part of the standard laptop pass
  tree (`pass buzz/relay/private-key`) plus an out-of-band copy of the
  per-service random secrets. Runbook documents the recovery path.
- **Compose vendor lag**: divergence between the vendored `compose.yml` and
  upstream is silent. The install script is idempotent and Compose applies
  only the diff, but new env vars or services added upstream will not
  surface unless `host-plane/buzz-compose.yml` is bumped. Owners should
  subscribe to the upstream repo's releases.
- **Loopback bind defers the rate-limit / TLS questions** to "if we ever
  expose this." That's fine for v0 (operator-only, single tenant, behind
  Tailscale) but means exposing Buzz publicly is a deliberate follow-up.
- **Two Nostr keypairs** now live on the laptop: Hermes's
  (`nostr/hermes-buzz/private-key`, ADR #0010) and the relay's
  (`buzz/relay/private-key`, this ADR). Same tool (`nak key generate`), same
  custody pattern (laptop pass → VPS), different roles. Easy to confuse;
  this ADR pins the names.
- **`BUZZ_AUTO_MIGRATE=true`** is on by default (upstream production default
  for the relay). First start runs the 30 numbered migrations. New upgrades
  also run new migrations on first boot; the install script will fail
  loudly if `docker compose pull relay` brings an incompatible migration.

## Open

- Whether `BUZZ_HTTP_PORT` should be moved off 3000 to avoid conflicts with
  anything else on `grr`. (None today; defer until something bites.)
- Whether to add a backup cron (`docker exec postgres pg_dump`) — the
  map's **Not yet specified** notes "Backup / disaster recovery beyond the
  keypair" as open work.