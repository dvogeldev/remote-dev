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

**When**: workspace move (new VPS, new region, fresh install after a deploy
ends) — never otherwise. The relay identity is per-deployment, not a
human. Past relay-signed events become unverifiable; that's the point of
a workspace move.

**On the laptop**:

```bash
# 1. Confirm the old key is in pass (so we can record it as "shut down" if needed)
pass show buzz/relay/private-key
old_nsec="$(pass show buzz/relay/private-key | head -n1)"
old_npub="$(pass show buzz/relay/private-key | sed -n '2p')"
echo "old relay: $old_npub  (shutting down)"

# 2. Destroy the old entry — per ADR #0012, the old relay key is deployment-
#    scoped, not a human identity, so retention serves no audit purpose.
pass rm -f buzz/relay/private-key

# 3. Generate the new keypair and store it under the SAME pass path
#    (install-buzz.sh will pick it up on the next run).
nak key generate                                       # hex secret on stdout
new_nsec="$(nak key generate)"
new_npub="$(nak key public "$new_nsec")"
printf '%s\n%s\n' "$new_nsec" "$new_npub" | pass insert -m -f buzz/relay/private-key >/dev/null

# 4. Push to grr via the install script (stages 1-4) + then the operator
#    fills RELAY_OWNER_PUBKEY for the new workspace.
HOST=grr ./scripts/install-buzz.sh
```

**On grr**: the install script restarts the relay container as part of its
post-pull stage, picking up the new `BUZZ_RELAY_PRIVATE_KEY`. Postgres is
**not** restored by the install script — that's the follow-up ticket.
If you have a `pg_dump` archive in `pass buzz/postgres-dumps/`, manually
restore it BEFORE the relay first boots:

```bash
ssh grr
cd ~/.buzz
# Pull the latest dump from pass
mkdir -p /tmp/restore
gpg -d ~/.password-store/buzz/postgres-dumps/<date>.sql.gpg 2>/dev/null \
  | docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

### Rotate Hermes's keypair

**When**: compromise only (nsec leaked to git, exfiltrated logs, stolen
device). Never scheduled. The new Hermes npub has no continuity from the
old one — clients following `npub10jrzt450...` won't auto-follow the
new key.

**On the laptop**:

```bash
# 1. Pull the current nsec as the audit record (we'll move it under rotated/)
old_nsec="$(pass show nostr/hermes-buzz/private-key | head -n1)"
old_npub="$(pass show nostr/hermes-buzz/private-key | sed -n '2p')"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

# 2. Move the old nsec into pass nostr/hermes-buzz/rotated/<ts> for retention.
#    Per ADR #0012: events signed by the old key stay valid forever; if anyone
#    needs to verify a past Hermes event against the old npub, this key is it.
mkdir -p ~/.password-store/nostr/hermes-buzz/rotated
pass show nostr/hermes-buzz/private-key \
  | gpg -e -r "David Vogel" \
  > /tmp/hermes-old.gpg
# Insert into pass as a one-line entry (the whole encrypted blob)
pass insert -m -f "nostr/hermes-buzz/rotated/$ts" < /tmp/hermes-old.gpg >/dev/null
rm -f /tmp/hermes-old.gpg

# 3. Generate the new nsec, replace the live pass entry.
#    Per ADR #0012: Hermes is a Bot in the relay; after rotation, BOTH old and
#    new Hermes pubkeys stay in the workspace so past events stay visible.
new_nsec="$(nak key generate)"
new_npub="$(nak key public "$new_nsec")"
printf '%s\n%s\n' "$new_nsec" "$new_npub" | pass insert -m -f nostr/hermes-buzz/private-key >/dev/null

# 4. Push to grr via unwrap-hermes-env.sh (writes ~/.hermes/.env + npub/nsec mirror).
HOST=grr ./scripts/unwrap-hermes-env.sh
```

**On grr**:

```bash
# 5. Restart the gateway so the plugin picks up the new nsec.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user restart hermes-gateway.service

# 6. Register the NEW Hermes pubkey as a Bot (the relay allows BOTH old and
#    new Hermes per ADR #0012, so don't remove the old entry).
cd ~/.buzz
docker compose exec -T relay buzz-admin add-member --pubkey "$new_npub" --role bot < /dev/null

# 7. Update BUZZ_ALLOWED_USERS in ~/.hermes/.env to include the new Hermes npub.
#    enable-hermes-buzz.sh does this idempotently — re-run it.
HOST=grr ./scripts/enable-hermes-buzz.sh

# 8. Update hermes-dashboard.service env (Hermes itself uses BUZZ_PRIVATE_KEY,
#    so the dashboard restart is needed too).
systemctl --user restart hermes-dashboard.service
```

**Sanity check**: post an `@new-hermes` mention from the operator and
verify a reply appears in the channel. If yes, both old and new Hermes
identities are alive and accepting traffic.

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

| Artifact | Where | Restore | Cadence |
|---|---|---|---|
| **Hermes nsec** | Laptop `pass nostr/hermes-buzz/private-key` (live) + `pass nostr/hermes-buzz/rotated/<ts>` (history per ADR #0012) + mirror at `~/.hermes/.env` and `~/.hermes/nostr.{npub,nsec}` on grr | pass → `unwrap-hermes-env.sh` | Already covered (ADR #0007) |
| **Relay nsec** | Laptop `pass buzz/relay/private-key` + mirror at `~/.buzz/.env` on grr | pass → `install-buzz.sh` (it re-uses existing pass entries) | Already covered (ADR #0007) |
| **Postgres data** (events, channels, members, FTS, audit log) | Docker volume `buzz-prod_buzz-postgres-data` | `pg_restore` from a `pass buzz/postgres-dumps/<date>.sql.gpg` archive (see "Postgres backup procedure" below) | **Weekly manual** for v0 (ADR #0012) |
| **MinIO data** (attachments) | Docker volume `buzz-prod_buzz-minio-data` | `mc mirror` to a fresh volume | Deferred (no real data in v0) |
| **Redis data** | Docker volume `buzz-prod_buzz-redis-data` | Replay only; ephemeral | N/A |
| **Git data** (NIP-34) | Docker volume `buzz-prod_buzz-git-data` | Host-volume backup | Deferred (no real data in v0) |
| **Compose file + unit + scripts** | This repo | `git pull` | On every commit |
| **`.env.example`** | This repo | `git pull` | On every commit |

The Postgres volume is the only one holding real user data; everything else
is regenerable from the secret store + this repo.

### Postgres backup procedure (weekly manual)

The operator runs this on grr; the dump ends up in the laptop's `pass`
tree (encrypted at rest by virtue of being in pass). The operator's
calendar reminder is the cadence mechanism.

```bash
# On grr — generate the dump, then pipe through ssh-agent so pass insert
# (which encrypts the entry with the operator's GPG key) runs on the laptop.
# pass IS the encryption (ADR-0007); we do NOT pre-encrypt with gpg here.
ssh grr <<'REMOTE'
set -euo pipefail
cd ~/.buzz
ts="$(date -u +%Y%m%dT%H%M%SZ)"
docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --clean --if-exists \
  > "/tmp/buzz-postgres-${ts}.sql"
ls -la "/tmp/buzz-postgres-${ts}.sql"
REMOTE

# Pull the dump from grr, push into pass (pass-encrypts it), clean up.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
ssh grr "cat /tmp/buzz-postgres-${ts}.sql" \
  | pass insert -m -f "buzz/postgres-dumps/${ts}.sql"
ssh grr "rm -f /tmp/buzz-postgres-${ts}.sql"
```

Notes:
- `--clean --if-exists` (pg_dump 17) makes the dump replayable into an
  empty DB after a fresh install — without `--if-exists`, the DROP
  statements fail on tables that don't yet exist.
- We do NOT `gpg -e` the dump before `pass insert`. pass already encrypts
  with the operator's GPG key (ADR-0007); double-encryption makes
  restore a two-stage process that install-buzz.sh can't run unattended.
- The `.sql` extension (not `.sql.gpg`) reflects that the on-disk file in
  pass is the SQL plaintext; pass handles the encryption envelope.

**Restore** (also from grr):

```bash
ssh grr
cd ~/.buzz
# Pick the latest dump; in a real recovery you'd pin to a specific ts.
dump="$(pass ls buzz/postgres-dumps/ | tail -n 1 | sed 's/.*buzz\/postgres-dumps\///;s/  *//')"
cat "$HOME/.password-store/buzz/postgres-dumps/${dump}" \
  | docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

Or just re-run `install-buzz.sh` — it detects the latest dump in pass,
restores automatically before bringing the relay up. See "Recover from
a fresh VPS" below.

This procedure is **manual**, not a cron. The install scripts do NOT
install a Postgres backup cron for v0 — the operator's calendar reminder
is the cadence mechanism. Revisit when there's a second agent or the
workspace holds more than ~7 days of irreplaceable activity (per ADR
#0012 Q9).

### Recover from a fresh VPS

A rebuilt `grr` with `pass` intact can be restored to a working
round-trip state with a single command from the laptop:

```bash
HOST=grr ./scripts/install-buzz.sh
```

That's the whole story. The script:

1. Detects the existing relay keypair in `pass buzz/relay/private-key` and reuses it (ADR #0012, recovery of the relay identity).
2. Detects the latest Postgres dump in `pass buzz/postgres-dumps/<date>.sql` and restores it into the freshly-provisioned Postgres before the relay boots.
3. Brings up the full stack via the systemd unit (`buzz.service`).
4. NIP-42 AUTH from Hermes works immediately because Hermes's nsec was also preserved (mirrored to `~/.hermes/.env` via `unwrap-hermes-env.sh`).

After the install, run `enable-hermes-buzz.sh` once to (re)wire the
plugin (idempotent — preserves existing `BUZZ_HOME_CHANNEL` /
`CHANNELS` / `ALLOWED_USERS`). No manual Postgres restore required.

**What's still manual**:

- The very first install on a brand-new `grr` (no `pass`, no volumes)
  is a chicken-and-egg: there's no dump to restore, no relay keypair to
  reuse. That path goes through Phase 1 + Phase 2 of the day-one
  procedure (operator creates the demo room, registers Hermes via
  `buzz-admin add-member`, etc.).
- An operator who runs `install-buzz.sh` mid-incident against a stack
  with live data (DB has tables, dump is older than the live state) will
  see the WARN message: the install refuses to overwrite and prompts for
  a manual `cat $dump | psql` replay.

**Verified end-to-end** (commit `cb30e39` follow-up): a
`docker compose down -v` wipe followed by `install-buzz.sh` brought
back the channel `085ef6ac-a52f-465d-b9bd-5f0c5d22594d` ("Hermes
Demo"), its 1 operator message, and the 2 relay members. The relay
container booted on the restored data and accepted NIP-42 AUTH from
Hermes within 7 healthcheck retries.

## Files in this repo

| Path | What |
|---|---|
| `host-plane/buzz-compose.yml` | Vendored Compose file (Apache-2.0 from upstream). |
| `host-plane/buzz/.env.example` | Env template; copy to `~/.buzz/.env` on grr. |
| `host-plane/buzz.service` | systemd --user unit driving `docker compose up`. |
| `scripts/install-buzz.sh` | AFK install on grr. Re-run to rotate secrets / push the relay keypair. Detects existing `pass buzz/relay/private-key` and reuses it (recovery story, ADR #0012); detects latest Postgres dump in `pass buzz/postgres-dumps/` and restores before bringing the relay up (#51). |
| `scripts/enable-hermes-buzz.sh` | Installs the real `buzz` CLI from the desktop AppImage; idempotently configures `~/.hermes/.env` (preserves existing `BUZZ_HOME_CHANNEL` / `BUZZ_CHANNELS` / `BUZZ_ALLOWED_USERS` on re-run); runs `hermes gateway install` + start. |
| `scripts/smoke-buzz.sh` | Three-check smoke test (liveness, NIP-42 from inside the container, round-trip over SSH tunnel). |
| `docs/adr/0011-buzz-host-plane-layout.md` | Loopback bind, vendoring policy, system unit shape. |
| `docs/adr/0012-keypair-rotation-and-backup.md` | Rotation triggers + backup cadence + recovery story for both keypairs. |

## Out of scope

- `cloudflared`-fronted exposure of Buzz (would require a second CF Access
  app, a public hostname, and a rate-limit strategy). v0 is loopback-only.
- TLS via the upstream `compose.caddy.yml` override. Operator reaches the
  relay through Tailscale or SSH; no public TLS.
- Multi-relay / multi-community mode. The single-host, single-relay,
  single-community self-host default is the v0 shape per ADR #0011.
- Production observability (Prometheus + alerting). Metrics are exposed on
  `127.0.0.1:9102`; wiring them into anything is a follow-up.
- Anti-spam / rate-limit policy. The relay ships only `AlwaysAllowRateLimiter`
  per research; v0 mitigates by loopback-only bind.
- Mobile clients, approval-gate workflow plumbing, attachments. Out of v0 per
  the map's Destination clause.
- An installed Postgres backup cron. v0 uses a calendar reminder + the
  manual procedure in "Backups" above. Revisit per ADR #0012 Q9.

## Done means

- `scripts/install-buzz.sh` runs cleanly on a fresh `grr` with `pass buzz/relay/private-key` and `pass buzz/postgres-dumps/<latest>.sql` already in place (recovery story per ADR #0012 + #51).
- `docker compose ps` on grr shows `relay`, `postgres`, `redis`, `minio`, `minio-init` all `running` (or `exited (0)` for `minio-init`).
- `curl -fsS http://127.0.0.1:8080/_liveness` on grr returns the liveness line.
- `scripts/smoke-buzz.sh` shows "AUTH challenge received" or a relay response in any of its three checks.
- After `docker compose down -v` + re-running `install-buzz.sh`, the previously-stored channel + messages + members reappear (verified commit `<follow-up>`).
- An operator-created room in the Buzz desktop client results in Hermes responding to an `@hermes` mention within a few seconds (round-trip text demo, the [#36](https://github.com/dvogeldev/remote-dev/issues/36) destination gate).
- This runbook is committed and linked from [#47](https://github.com/dvogeldev/remote-dev/issues/47).