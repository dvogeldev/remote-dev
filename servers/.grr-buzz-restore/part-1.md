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
| **Postgres data** (events, channels, members, FTS, audit log) | Docker volume `buzz-prod_buzz-postgres-data` | `pg_restore` from a `pass buzz/postgres-dumps/<date>.sql` archive (see "Postgres backup procedure" below). The procedure also runs `scripts/prune-buzz-pg-dumps.sh` to enforce 90-day retention. | **Weekly manual** for v0 (ADR #0012) |
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
