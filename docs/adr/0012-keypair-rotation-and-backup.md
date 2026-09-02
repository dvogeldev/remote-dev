# Keypair rotation & backup (Hermes + relay)

For Hermes's Nostr identity and the relay's workspace identity, rotation is compromise-only (Hermes) or workspace-move-only (relay); old Hermes keys are retained indefinitely under `pass nostr/hermes-buzz/rotated/<ts>` so past events stay verifiable, while old relay keys are destroyed on workspace move (the relay identity is per-deployment, not a human). Backups cover the relay's Postgres (events, channels, members, FTS index) via a weekly manual `pg_dump | gpg | pass insert` cadence using the operator's laptop GPG key — Hermes's nsec and the relay nsec are already covered by pass per ADR #0007. The install scripts already detect existing pass entries and skip regeneration, so rebuilding a VPS no longer destroys the relay identity; Postgres restoration remains a follow-up ticket because it requires detecting and replaying a `pass buzz/postgres-dumps/<date>.sql.gpg` archive before the relay boots.

## Consequences

### Nostr identity IS the key — rotation is a hard fork

Rotation produces a fresh npub; clients following the old npub do NOT auto-follow the new one. (NIP-09 key-rotation announcements let an old key declare "I am now X," but adoption is voluntary — clients aren't required to honor it.) For v0 with a single operator + a single agent, a rotation event is publishable but no one is listening. The pragmatic v0 stance: accept the discontinuity; clients re-add the new npub manually.

### Workspace history survives rotation (Hermes)

Events signed by the old Hermes key remain cryptographically valid forever. Removing the old key from the workspace makes those events unverifiable, so the default is to **keep both** the rotated-out Hermes key and the new one as workspace members. Cost: two `kind:0` profile rows in the relay, one extra pubkey in `BUZZ_ALLOWED_USERS`. Benefit: the workspace directory shows the full Hermes history with a clear "rotated" annotation.

### Relay identity is deployment-scoped, not human-scoped

The relay's nsec is bound to the deployment (the VPS, the BUZZ_DOMAIN, the Postgres volume). When the deployment ends (new VPS, new region, fresh install), the relay identity is destroyed — there's no continuity because nothing should be talking to the old relay. Operators document the old npub in a "shutting down" notice if there were external clients, but for v0 (loopback-only, no public hostname) the question is moot.

### Recovery story gap

Rebuilding a VPS today preserves the relay keypair (install-buzz.sh reuses `pass buzz/relay/private-key` if present) but does NOT restore Postgres data. The follow-up ticket covers `pg_dump`-restore detection during install. Until that ships, an operator rebuilding `grr` loses their workspace history unless they manually `psql -f <dump>.sql` the relay after install. The runbook documents this explicitly so the operator isn't surprised.

## Considered options (for the rotation-trigger question)

- **(a) Compromise only** ← chosen for Hermes. Nostr identities are typically held for life; the coordination cost of rotation (clients re-add the new npub, past events stay signed by the old key) has no upside when there's no compromise. Re-evaluate when the workspace has multiple agents.
- **(b) Annual schedule** — common for SSH host keys but heavyweight for personal Nostr keys with a single user. Defer until the workspace has more than one agent.
- **(c) Operator identity change** — couples Hermes's key to the human operator's key rotation, which is itself a rare event. Adds coupling without solving a real problem in v0.
- **(d) Workspace re-key** — rotates when the whole workspace moves, but the relay already rotates on workspace move (per the relay half of the decision). Hermes's key doesn't need to follow.