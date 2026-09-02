# Buzz relay on grr-remote-dev-01 — runbook

Resolves [#47](https://github.com/dvogeldev/remote-dev/issues/47). Parent: [#36](https://github.com/dvogeldev/remote-dev/issues/36).

## What this gives you

- A self-hosted Block Buzz relay running as a Docker Compose stack on `grr-remote-dev-01`, bound to `127.0.0.1:3000`. Loopback-only: no public port, no public hostname in v0.
- Postgres 17, Redis 7, MinIO, and a git-volume behind the relay, all in one Compose project (`buzz-prod`).
- Hermes (the agent) reaches the relay at `ws://127.0.0.1:3000` from the same host — no extra networking required.
- Operator reaches the Buzz desktop client from the laptop via Tailscale or an SSH tunnel.

## Decisions locked

| | |
|---|---|
| Compose artifact | Vendored at `host-plane/buzz-compose.yml` (Apache-2.0 from upstream `block/buzz/deploy/compose/compose.yml`) |
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
  Two options: (a) add `127.0.0.1 grr-remote-dev-01` to the laptop's
  `/etc/hosts` so the Tailscale hostname resolves as `127.0.0.1`, or (b)
  run the relay in multi-community mode (deferred — out of scope for v0).

This is the most common day-one papercut. The install script sets `BUZZ_DOMAIN=127.0.0.1` automatically; the smoke test verifies the relay accepts connections with that Host header.

## Day-one procedure

### Phase 1 — Install (AFK from the laptop)

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/install-buzz.sh
```

This lays down `~/.buzz/{compose.yml,.env.example}`, the systemd user unit
`~/.config/systemd/user/buzz.service`, enables linger for `david` on grr,
generates the relay keypair (via `nak key generate`, stores in
`pass buzz/relay/private-key`), generates backing-service secrets, sets
`BUZZ_DOMAIN=127.0.0.1` and related URLs, and prompts you to set
`RELAY_OWNER_PUBKEY` in `~/.buzz/.env` before continuing.

If the script stops at the `RELAY_OWNER_PUBKEY` gate:

```bash
ssh grr '$EDITOR ~/.buzz/.env'         # set RELAY_OWNER_PUBKEY=<operator-hex>
HOST=grr ./scripts/install-buzz.sh     # resumes: pull + start unit + healthcheck wait
```

The script ends with the unit active (`systemctl --user is-active
buzz.service` returns `active`) and all five containers healthy. The
unit's lifecycle IS the stack's lifecycle: `stop` brings the containers
down, `start` brings them back up.

### Phase 2 — Admin bootstrap (HITL, do these in order on grr)

**2.1 Confirm Hermes's pubkey is on the VPS.**

```bash
ssh grr 'cat ~/.hermes/nostr.npub'
```

If empty, run `scripts/unwrap-hermes-env.sh` from the laptop first (this
unwraps `nostr/hermes-buzz/private-key` from pass into `~/.hermes/.env` and
the chezmoi mirror lays down the npub/nsec files; see ADR #0010).

**2.2 Register Hermes as a Bot.**

```bash
ssh grr
cd ~/.buzz
hermes_hex=$(nak pubkey "$(grep '^BUZZ_PRIVATE_KEY=' ~/.hermes/.env | cut -d= -f2-)")
docker compose exec relay buzz-admin add-member \
    --pubkey "$hermes_hex" --role bot
```

This is the bootstrap that makes NIP-42 AUTH from `BUZZ_PRIVATE_KEY`
accepted by the relay. (Requires `nak` on grr or do the equivalent with
`python -c` against the hex pubkey derivation.)

**2.3 Open the Buzz desktop client from the laptop.**

The relay is loopback-only. Pick one path:

- **SSH tunnel** — `ssh -L 3000:127.0.0.1:3000 grr`, then point the client
  at `ws://127.0.0.1:3000`. The Host header will be `127.0.0.1:3000`,
  which matches `BUZZ_DOMAIN=127.0.0.1` on the relay.
- **Tailscale** — only works after adding `127.0.0.1 grr-remote-dev-01`
  to the laptop's `/etc/hosts` (see the BUZZ_DOMAIN gotcha above). Then
  `ws://grr-remote-dev-01:3000` resolves through to the loopback relay.

Sign in with the operator's Nostr keypair (the one whose pubkey is in
`RELAY_OWNER_PUBKEY`).

**2.4 Create the demo room.**

In the Buzz desktop UI: **create a new room**, name it (e.g. `hermes-room`),
and copy its UUID.

**2.5 Wire the room into Hermes.**

On grr, add the room to `~/.hermes/.env` and restart the gateway:

```bash
ssh grr
room=<paste-uuid-here>
echo "BUZZ_HOME_CHANNEL=$room"  >> ~/.hermes/.env
echo "BUZZ_CHANNELS=[$room]"    >> ~/.hermes/.env
# BUZZ_RELAY_URL defaults to ws://127.0.0.1:3000 (matches BUZZ_DOMAIN); set
# explicitly only if you need a different relay URL.
# echo "BUZZ_RELAY_URL=ws://127.0.0.1:3000" >> ~/.hermes/.env
systemctl --user restart hermes-dashboard.service
```

From this point Hermes (the gateway) sees the room and responds to
@-mentions per the v0 policy (no DMs, mention-gated). See #43 for the room
semantics that produced this shape.

### Phase 3 — Verify

**3.1 Smoke from the laptop.**

```bash
HOST=grr ./scripts/smoke-buzz.sh
```

Four checks: HTTP liveness/readiness on the VPS, WS upgrade + NIP-42 AUTH
challenge on 127.0.0.1:3000, event round-trip (relay returns OK/CLOSED —
proves the wire is alive). Wire is alive if any of the four produces a
relay response.

**3.2 Hermes round-trip (the official demo gate).**

With the demo room open in the Buzz client and Hermes connected:

1. As the operator, post a message in the room: `@hermes hello`.
2. Hermes replies (per the v0 gateway config).
3. Check `journalctl --user -u hermes-dashboard.service -n 80` for the
   gateway log line that proves it received the relay event and dispatched
   the reply.

This is the round-trip text demo [#36](https://github.com/dvogeldev/remote-dev/issues/36) calls for.

## Operating

### Manage the stack

```bash
ssh grr
systemctl --user status|start|stop|restart buzz.service
cd ~/.buzz && docker compose ps
cd ~/.buzz && docker compose logs -f relay
cd ~/.buzz && docker compose logs -f relay postgres redis minio
```

The unit runs `docker compose up` in the foreground; **stopping the unit
stops the containers**. If you want the stack up but the unit stopped,
restart the unit.

### Upgrade the relay image

```bash
ssh grr
cd ~/.buzz
# 1. snapshot .env first (load-bearing; the relay key lives here)
cp .env .env.bak.$(date +%Y%m%d)
# 2. stop the unit (so the foreground compose process releases the relay)
systemctl --user stop buzz.service
# 3. pull the new image
docker compose pull relay
# 4. start the unit back up (migrations auto-run if BUZZ_AUTO_MIGRATE=true)
systemctl --user start buzz.service
# 5. validate
curl -fsS http://127.0.0.1:8080/_liveness
docker compose logs --tail=120 relay
```

Per upstream guidance, before bumping:

- Read the relay release notes (`block/buzz` GitHub releases, `relay-*`
  filter once those tags land).
- Confirm `BUZZ_RELAY_PRIVATE_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET`, DB /
  Redis / S3 secrets in `.env` haven't changed (Compose will preserve them
  but verify after the restart).
- For a `:main` bump, expect new migrations; for a `:sha-<7>` bump on a
  release tag, expect a release-notes-driven change set.

### Rotate the relay keypair

The relay keypair signs relay-level events (deletions, channel meta). It is
load-bearing but does NOT identify a human or agent; rotate it freely
without losing data, but past relay-signed events become unverifiable.

```bash
# on the laptop
nak key generate                                       # new nsec/npub
pass insert -m -f buzz/relay/private-key <<<"${new_nsec}
${new_npub}"

# push the new nsec into ~/.buzz/.env on grr
HOST=grr ./scripts/install-buzz.sh                     # stages 1-4, then exits at the gate

# on grr
cd ~/.buzz
docker compose restart relay                           # picks up the new key
```

### Rotate Hermes's keypair

Handled by `scripts/unwrap-hermes-env.sh` plus the Hermes restart — see
ADR #0010. The membership record in `buzz-admin` is keyed by Hermes's
**pubkey**, so after rotating the nsec the new pubkey needs to be added as a
member and the old one removed.

### Add a second member (human operator or another agent)

```bash
ssh grr
cd ~/.buzz
docker compose exec relay buzz-admin add-member \
    --pubkey <their-hex-pubkey> --role <admin|member|guest|bot>
```

Operators should be `admin` or `owner` (matches the same role in
`RELAY_OWNER_PUBKEY`). Other agents are `bot`.

### Backups

| Artifact | Where | Restore |
|---|---|---|
| Relay Nostr keypair | Laptop `pass` + `~/.buzz/.env` on grr | `pass buzz/relay/private-key` → re-run install-buzz.sh stages 1-3 |
| Postgres data | Docker volume `buzz-postgres-data` | `docker run --rm -v buzz-postgres-data:/from -v $(pwd):/to postgres:17-alpine pg_dump ...` or rely on host-volume backup |
| MinIO data | Docker volume `buzz-minio-data` | `mc mirror` or host-volume backup |
| Redis data | Docker volume `buzz-redis-data` | Replay only; ephemeral (AOF) |
| Git data (NIP-34) | Docker volume `buzz-git-data` | Host-volume backup |
| Compose file | This repo (`host-plane/buzz-compose.yml`) | `git pull` |
| `.env.example` template | This repo (`host-plane/buzz/.env.example`) | `git pull` |

The Postgres volume is the largest and the only one that holds real user
data (events, channels, audit log, FTS). Backup cadence is a separate
ticket (see map #36's **Not yet specified**: "Backup / disaster recovery
beyond the keypair").

## Files in this repo

| Path | What |
|---|---|
| `host-plane/buzz-compose.yml` | Vendored Compose file (Apache-2.0 from upstream). |
| `host-plane/buzz/.env.example` | Env template; copy to `~/.buzz/.env` on grr. |
| `host-plane/buzz.service` | systemd --user unit driving `docker compose up`. |
| `scripts/install-buzz.sh` | AFK install on grr. Re-run to rotate secrets / push the relay keypair. |
| `scripts/smoke-buzz.sh` | Three-check smoke test (liveness, NIP-42 from inside the container, round-trip over SSH tunnel). |
| `docs/adr/0011-buzz-host-plane-layout.md` | This ADR. |

## Out of scope

- `cloudflared`-fronted exposure of Buzz (would require a second CF Access
  app, a public hostname, and a rate-limit strategy). v0 is loopback-only.
- TLS via the upstream `compose.caddy.yml` override. Operator reaches the
  relay through Tailscale or SSH; no public TLS.
- Backups beyond the keypair (map #36's **Not yet specified**).
- Multi-relay / multi-community mode. The single-host, single-relay,
  single-community self-host default is the v0 shape per ADR #0011.
- Production observability (Prometheus + alerting). Metrics are exposed on
  `127.0.0.1:9102`; wiring them into anything is a follow-up.
- Anti-spam / rate-limit policy. The relay ships only `AlwaysAllowRateLimiter`
  per research; v0 mitigates by loopback-only bind.
- Mobile clients, approval-gate workflow plumbing, attachments. Out of v0 per
  the map's Destination clause.
- A backup/recovery cron for Postgres / MinIO (deferred).

## Done means

- `scripts/install-buzz.sh` runs cleanly on a fresh `grr` with `pass buzz/relay/private-key` already in place.
- `docker compose ps` on grr shows `relay`, `postgres`, `redis`, `minio`, `minio-init` all `running` (or `exited (0)` for `minio-init`).
- `curl -fsS http://127.0.0.1:8080/_liveness` on grr returns the liveness line.
- `scripts/smoke-buzz.sh` shows "AUTH challenge received" or a relay response in any of its three checks.
- `buzz-admin add-member --pubkey <hermes-hex> --role bot` returns success.
- An operator-created room in the Buzz desktop client results in Hermes responding to an `@hermes` mention within a few seconds (round-trip text demo, the [#36](https://github.com/dvogeldev/remote-dev/issues/36) destination gate).
- This runbook is committed and linked from [#47](https://github.com/dvogeldev/remote-dev/issues/47).