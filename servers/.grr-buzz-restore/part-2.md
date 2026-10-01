  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --clean --if-exists \
  > "/tmp/buzz-postgres-${ts}.sql"
ls -la "/tmp/buzz-postgres-${ts}.sql"
REMOTE

# Pull the dump from grr, push into pass (pass-encrypts it), clean up.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
ssh grr "cat /tmp/buzz-postgres-${ts}.sql" \
  | pass insert -m -f "buzz/postgres-dumps/${ts}.sql"
ssh grr "rm -f /tmp/buzz-postgres-${ts}.sql"

# Prune old dumps (ADR #0012 Q9: 90-day retention). Idempotent — runs as
# part of the weekly backup so operators can't forget. Override the
# retention window via BUZZ_PG_DUMPS_RETENTION_DAYS.
./scripts/prune-buzz-pg-dumps.sh
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
