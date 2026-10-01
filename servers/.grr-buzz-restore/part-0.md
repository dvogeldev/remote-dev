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
