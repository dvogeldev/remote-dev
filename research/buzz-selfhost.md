# Block Buzz — self-host surface and persistence

> Resolves [#38](https://github.com/dvogeldev/remote-dev/issues/38).
> Parent: [#36](https://github.com/dvogeldev/remote-dev/issues/36) (Hermes ↔ Buzz channel).
> Sources cited inline. Every claim traces to a primary doc, the upstream `block/buzz` repo, or the GHCR package page.

## TL;DR

Buzz is the relay, not a Slack app with a relay bolted on. The self-host surface is one Rust binary (`buzz-relay`) plus four backing services (Postgres, Redis, MinIO/S3, git volume) plus optional Caddy for TLS, published as a first-party Compose bundle at `deploy/compose/` in `github.com/block/buzz` and pulled as **`ghcr.io/block/buzz`**. The image ships `buzz-admin` so first-admin bootstrap is a CLI invocation against the live container, not a SQL insert. The relay does not federate with public Nostr relays by default — it is the single source of truth for one community — so "private Nostr relay we run" from the parent map drops in cleanly.

| Question | Answer (one line) | Source |
| --- | --- | --- |
| Official image? | `ghcr.io/block/buzz` (GHCR, public, Apache-2.0) | [package page](https://github.com/block/buzz/pkgs/container/buzz), [`RELEASING.md`](https://github.com/block/buzz/blob/main/RELEASING.md) |
| Compose pattern? | `deploy/compose/compose.yml` + optional `compose.caddy.yml` override | [`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md) |
| Persistence? | Postgres 17 (events, FTS, audit) + Redis 7 (pub/sub, presence) + MinIO/S3 (Blossom media + git CAS) + git volume | [`compose.yml`](https://github.com/block/buzz/blob/main/deploy/compose/compose.yml), [`ARCHITECTURE.md` §8](https://github.com/block/buzz/blob/main/ARCHITECTURE.md) |
| Migration story? | 30 numbered `migrations/*.sql`, opt-in via `BUZZ_AUTO_MIGRATE=true`; admin CLI also runs them | [`deploy/compose/.env.example`](https://github.com/block/buzz/blob/main/deploy/compose/.env.example), [repo `migrations/`](https://github.com/block/buzz/tree/main/migrations) |
| Multiple Nostr relays? | Not in the self-host default. One relay = one community = one URL. Multi-community is per-host behind one shared backend | [`ARCHITECTURE.md` §1](https://github.com/block/buzz/blob/main/ARCHITECTURE.md), [`NOSTR.md`](https://github.com/block/buzz/blob/main/NOSTR.md) |
| First admin? | Run `buzz-admin add-member --pubkey <hex> --role admin` inside the relay container; identity is a Nostr keypair, not OAuth | [`ARCHITECTURE.md` §6 (`buzz-admin`)](https://github.com/block/buzz/blob/main/ARCHITECTURE.md), [`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md) |
| Upgrade story? | Image bump; `relay-v*` semver tags exist; `BUZZ_RELAY_PRIVATE_KEY` and DB passwords must stay stable across restarts | [`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md), [`RELEASING.md`](https://github.com/block/buzz/blob/main/RELEASING.md) |

---

## 1. Image, registry, and image publication

- **Registry**: GitHub Container Registry, namespace `block/buzz`, image name `buzz`. Package page: <https://github.com/block/buzz/pkgs/container/buzz>. The page confirms public visibility, Apache-2.0 license, 116 contributors, 390K+ downloads, and that the latest push was minutes-old `:sha-<7>` + `:main` tags.
- **Tag taxonomy** (from [`RELEASING.md`](https://github.com/block/buzz/blob/main/RELEASING.md)):
  - **Rolling**: every push to `main` publishes `:main` and `:sha-<7>` (and matching `:debug-main`, `:debug-sha-<7>` for profiling).
  - **Stable**: `relay-v<version>` immutable tag (e.g. `relay-v0.5.20`-style; relay lane version authority is `crates/buzz-relay/Cargo.toml`). Stable tags update version aliases and `:latest`.
- **The relay binary is shipped in the image at `/usr/local/bin/buzz-relay`** alongside `buzz-admin` and `buzz-acp` (per `ARCHITECTURE.md` §6 `buzz-admin` entry: *"The `buzz-admin` binary is shipped in the relay Docker image (`/usr/local/bin/buzz-admin`) and is the recommended way to manage relay membership in production"*).
- **Tag pinning guidance** from upstream, verbatim: *"Default `BUZZ_IMAGE` tracks `ghcr.io/block/buzz:main` for early testing. Pin it to `ghcr.io/block/buzz:sha-<7>` or a semver release tag for production once available."* ([`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md)).

For this repo's host-plane goal (a single relay we control), the `relay-v*` tag is the right pin. `:main` is explicitly flagged as "for early testing."

---

## 2. Recommended Compose pattern

The project ships a dedicated production Compose bundle at `deploy/compose/` — explicitly separated from the root `docker-compose.yml`, which is "for day-to-day development only" ([`README.md`](https://github.com/block/buzz/blob/main/README.md)). Files in `deploy/compose/`:

| File | Role |
| --- | --- |
| `compose.yml` | Base — relay + Postgres 17 + Redis 7 + MinIO + git volume |
| `compose.caddy.yml` | Override — drops the direct relay port, adds Caddy 2 for Let's Encrypt TLS |
| `compose.dev.yml` | Override — exposes DB/Redis/MinIO/Adminer/Prometheus on host ports for debugging |
| `.env.example` | Production env template (`RELAY_OWNER_PUBKEY`, secrets, `BUZZ_IMAGE`, `BUZZ_HTTP_PORT`, etc.) |
| `Caddyfile`, `run.sh` | TLS automation and operator script (backups, status, `add-member`) |
| `README.md` | Quick-start, production notes, validation steps |

### 2a. Services in `compose.yml` (verified from raw fetch)

```
relay        — image: ${BUZZ_IMAGE:-ghcr.io/block/buzz:main}
              env: BUZZ_BIND_ADDR=0.0.0.0:3000, BUZZ_HEALTH_PORT=8080, BUZZ_METRICS_PORT=9102,
                   DATABASE_URL, REDIS_URL, BUZZ_S3_ENDPOINT=http://minio:9000,
                   BUZZ_S3_ADDRESSING_STYLE=path, BUZZ_AUTO_MIGRATE=${BUZZ_AUTO_MIGRATE:-false}
              healthcheck: GET /_readiness via /dev/tcp (image ships bash, no curl)
postgres     — image: postgres:17-alpine; vol buzz-postgres-data
redis        — image: redis:7-alpine, appendonly + requirepass; vol buzz-redis-data
minio        — image: minio/minio; vol buzz-minio-data
minio-init   — creates the bucket; service_completed_successfully
```

`compose.caddy.yml` adds a `caddy:2-alpine` service with `${CADDY_HTTP_PORT:-80}:80` and `${CADDY_HTTPS_PORT:-443}:443`, depending on `relay: service_healthy`. The override uses Compose's `!reset` tag to null out the direct relay port.

### 2b. Quick-start path (upstream, verbatim from `deploy/compose/README.md`)

```bash
cd deploy/compose
cp .env.example .env
$EDITOR .env       # replace every CHANGE_ME value
./run.sh start

# Or with automatic Let's Encrypt via Caddy:
BUZZ_COMPOSE_TLS=true ./run.sh start
```

Upstream also gives a validation recipe: `./run.sh config`, `./run.sh start`, then `curl http://127.0.0.1:${BUZZ_HTTP_PORT}/_liveness`, then `./run.sh status`.

### 2c. Ports (defaults)

| Port | Service | Source |
| --- | --- | --- |
| 3000 | relay WS + HTTP (`BUZZ_HTTP_PORT`) | `compose.yml`, `BUZZ_BIND_ADDR` |
| 8080 | relay health (`/_liveness`, `/_readiness`) | `compose.yml` (`BUZZ_HEALTH_PORT`) |
| 9102 | relay metrics (Prometheus) | `compose.yml` (`BUZZ_METRICS_PORT`) |
| 5432 | Postgres | base `compose.yml` |
| 6379 | Redis | base `compose.yml` |
| 9000 / 9001 | MinIO API / console | dev override only |
| 80 / 443 | Caddy | `compose.caddy.yml` |

### 2d. Volumes (persistent)

- `buzz-postgres-data` → `/var/lib/postgresql/data`
- `buzz-redis-data` → `/data` (AOF persistence on)
- `buzz-minio-data` → MinIO data dir
- `buzz-git-data` → `/data/git` (NIP-34 bare repos + pack cache)
- `buzz-caddy-data`, `buzz-caddy-config` → Caddy certs/config (only when TLS override applied)

---

## 3. Persistence model

### 3a. Postgres — events, channels, audit, FTS

- Engine: **Postgres 17** (per `compose.yml`: `image: postgres:17-alpine`; ARCHITECTURE §8 confirms "Postgres 17"). The repo's local-dev `.env.example` mentions both Postgres and **Typesense** as an alternative search backend — Typesense is the *local-dev* path; production Compose does **not** ship Typesense, instead relying on Postgres FTS.
- ORM/runtime: `sqlx = "0.9"` with `runtime-tokio`, `tls-rustls`, `postgres`, `uuid`, `chrono`, `json` features ([`Cargo.toml`](https://github.com/block/buzz/blob/main/Cargo.toml)). Important: ARCHITECTURE §9 calls out "**No sqlx offline query cache** — uses `sqlx::query()` (runtime) not `sqlx::query!()` (compile-time). No `.sqlx/` directory." That removes one common operational papercut (no offline data to refresh) but means query bugs only surface at runtime.
- Schema lives at `migrations/` — **30 numbered files** (verified via the repo contents API): `0001_initial_schema.sql` through `0030_community_deletion_recovery.sql`. Numbered SQL files in chronological order; pure forward migrations, no rollback files.
- Migration runner: `BUZZ_AUTO_MIGRATE=true` runs them at relay startup, gated on the image containing "embedded SQLx migrations." Otherwise run `buzz-admin migrate` manually before first start ([`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md)).
- Key tables (from `ARCHITECTURE.md` §8): `events` (monthly range-partitioned), `channels`, `channel_members` (with soft-delete `removed_at`), `workflows`, `workflow_runs`, `workflow_approvals` (tokens stored as SHA-256 hash), `audit_log` (hash-chained, per-community in multi-community mode), `delivery_log`.
- Search: **`events.search_tsv` generated `tsvector` column with a GIN index**, populated on insert via `to_tsvector('simple', content)`. No separate search service in production. Kinds `1059`, `30300`, `30622` are storage-level unsearchable (`CASE WHEN kind IN (…) THEN NULL`). In multi-community mode, every query is BitmapAnd'd with a `community_id` predicate.
- Buzz publishes the list of migrations on every release; ARCHITECTURE.md doesn't enumerate the latest count but the `migrations/` directory listing confirms 30 files at the time of writing.

### 3b. Redis — pub/sub, presence, typing, rate-limit plumbing

- Engine: **Redis 7** (`redis:7-alpine`).
- Persistence: appendonly file (`--appendonly yes`).
- Uses (per ARCHITECTURE §6 `buzz-pubsub`):
  - Pub/sub fan-out for channel events (`PUBLISH buzz:channel:{uuid}`); dedicated `PSUBSCRIBE` connection (not from pool — pool connections can't hold PSUBSCRIBE state).
  - Presence: `SET buzz:presence:{pubkey_hex} {status} EX 180` — 180-second TTL, 3× the 60s heartbeat interval.
  - Typing: `ZADD buzz:typing:{channel_id} {now_unix} {pubkey_hex}` + 5s activity window + 60s key TTL.
  - Multi-node fan-out is wired end-to-end; local-echo dedup via `AppState.local_event_ids`.

### 3c. S3 / MinIO — media + git CAS (Blossom)

- Engine: **MinIO** (S3-compatible) bundled in the Compose stack.
- Wire protocol: Blossom (`PUT /media/upload`, `GET /media/{sha256_ext}`). ARCHITECTURE §6 `buzz-relay` HTTP endpoints: `PUT /media/upload` (50 MB limit), `GET/HEAD /media/{sha256_ext}`.
- **Critical gotcha** from upstream, verbatim: *"The bundled Compose stack fixes the relay endpoint to `http://minio:9000` and `BUZZ_S3_ADDRESSING_STYLE=path`: Docker DNS resolves `minio`, not `<bucket>.minio`. It is not configurable for an external S3 provider through `.env`; use the Helm chart or a custom Compose configuration for providers such as new Railway Storage Buckets that require `virtual` addressing."* ([`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md)).
- Implication for this repo's host-plane goal: stick with bundled MinIO unless we want to maintain a custom Compose fork.
- Media auth: every `GET/HEAD /media/*` requires Blossom `t=get` auth and relay membership (per `.env.example` notes).

### 3d. Git — NIP-34 bare repos

- NIP-34 git events (patches, repo announcements, status) and a hosting backend live behind the relay's HTTP endpoints (`/git/{owner}/{repo}/info/refs`, `/git-upload-pack`, `/git-receive-pack`).
- `BUZZ_GIT_REPO_PATH=./repos` (default). In the Compose bundle the path is `/data/git`, mounted as the `buzz-git-data` volume. A process-local pack/index cache (`BUZZ_GIT_PACK_CACHE_PATH`) defaults to on with a 5 GiB cap.
- Out of v0 scope per the parent map (round-trip text only), but the storage layer is already in the bundle so enabling git later means turning on an env var, not adding a service.

### 3e. Backups

Upstream ships a backup checklist via `./run.sh backup-hint`. The three persistent items that matter: `.env` (all secrets — lose it, lose the workspace), Postgres volume (`pg_dump` or volume snapshot), MinIO volume (mirror to S3 with `mc mirror`).

---

## 4. Relay configuration (Nostr relay list)

This is the load-bearing question for #36. The answer is unambiguous: **the self-hosted Buzz relay is itself the Nostr relay. There is no separate "outbox" relay list to configure for a single-community self-host.**

### 4a. The relay URL selects the community

From `ARCHITECTURE.md` §1, verbatim:

> *"The self-hosted default remains one host, one relay process, one implicit community. Multi-community deployments move that semantic boundary one level up: `req.community = resolve_host(connection.host)` is established before AUTH, EVENT, REQ, REST, media, git, search, workflow, or pub/sub handling. Unknown hosts fail closed, and NIP-98/API-token stamps must agree with the host-derived community rather than overriding it."*

The relay URL/domain is authoritative for the workspace. The host-plane pattern called out in #36 (Buzz behind `cloudflared` or loopback-only like `hermes-dashboard`) maps directly onto this — there is no second relay to federate with.

### 4b. "Multi-relay support" — what it actually means in Buzz

Buzz is **not** a multi-source Nostr client. It does not pull events from public relays like `relay.damus.io` and merge them. The relay you run is the only source of truth. Multi-relay-style features that do exist:

- **Multi-community** (host a relay that serves many communities via different domains/subdomains, with shared Postgres/Redis/MinIO). Requires explicit multi-community mode and a host-→-community resolver; *not* the self-host default. Described in ARCHITECTURE §1 and `NOSTR.md` §"Community scope."
- **Multi-node fan-out** at the Redis layer (one Postgres, one Redis, multiple `buzz-relay` processes behind a load balancer). Wired end-to-end (ARCHITECTURE §6 `buzz-pubsub`), local-echo dedup via `AppState.local_event_ids`. The production Compose bundle ships a single relay, but the architecture is multi-node-ready.
- **Replication heartbeat** (migration `0026_replica_heartbeat.sql`) — exists in the migration set, implies there's a documented heartbeat protocol for replicas. Not yet surfaced in upstream docs as a turn-key HA recipe.

What this means for #36: the "private Nostr relay we run" mentioned in the map is literally Buzz's `buzz-relay`. We don't need to run `nostr-rs-relay` or similar separately. Hermes, as an agent, just gets a Nostr keypair (`BUZZ_PRIVATE_KEY`) and connects to `wss://buzz.<host>/` like any other client (or via `buzz-acp` if we want the ACP harness).

### 4c. Third-party Nostr clients (verified)

`NOSTR.md` confirms: *"Buzz is a Nostr relay that speaks NIP-29 (relay-based groups) natively. Third-party Nostr clients connect directly to `buzz-relay` using NIP-29 and NIP-42 authentication."* Hermes-side Nostr client implementations (Damus, Amethyst, Snort-style) can talk to a self-hosted Buzz if we wanted to validate end-to-end Nostr behavior independently of Buzz's own desktop client. Hermes-as-agent connects via `buzz-cli` or via raw NIP-01/NIP-42 (it doesn't need a UI client).

### 4d. Single-relay architecture trade-off (worth flagging)

`VISION_SOVEREIGN.md` and `ARCHITECTURE.md` are explicit that the single-relay default is a *sovereignty* choice, not a limitation: every community gets one canonical relay URL that becomes its identity root. If the relay goes down, the workspace is down — there is no gossip or replication to other Buzz relays for community state. For our use case (host-plane, behind cloudflared, single operator) this is exactly what we want.

---

## 5. Auth and admin bootstrap

### 5a. First admin

The model is **Nostr keypairs, not OAuth**. There is no email signup, no password reset, no OAuth provider. Every principal (human or agent) holds a secp256k1 Nostr keypair and signs every action. Bootstrap is:

1. Generate a Nostr keypair (any Nostr tool — `buzz-admin generate-key`, `nak keygen`, `nostr-tools`, etc.).
2. Run `buzz-admin add-member --pubkey <hex|npub> --role admin` against the running relay container. The README directs: *"Use `./run.sh add-member`, `./run.sh remove-member`, and `./run.sh list-members` in Docker Compose deployments."*
3. The admin connects from the Buzz desktop client (or any NIP-42/NIP-29 client), authenticates with the keypair (NIP-42 challenge → signed response), and is now recognized as that pubkey with the admin role.

Roles are `Owner`, `Admin`, `Member`, `Guest`, `Bot` (ARCHITECTURE §6 `buzz-db`). Membership changes publish kind:13534 roster events so other relays in a multi-community setup can pick them up.

### 5b. Optional admin dashboard (moderation surface)

Per `.env.example` and `deploy/compose/.env.example`:

- `BUZZ_ADMIN_HOST=admin.buzz.example.com` — opt-in. Off by default; the admin surface is absent unless this is set.
- `BUZZ_ADMIN_AUTH=nip98` (default) — NIP-98 HTTP Auth: each request carries an `Authorization: Nostr` header with a signed kind:27235 event. Authorized principals come from:
  1. `RELAY_OPERATOR_PUBKEYS` (comma-separated hex)
  2. `RELAY_OWNER_PUBKEY` (implicit fallback)
  3. The `relay_operators` DB table (DB-managed roster).
- `BUZZ_ADMIN_AUTH=disabled` — no app-level auth. The relay logs a WARN. Use only when the admin API is already protected at the network layer (VPN, private ingress).
- `BUZZ_ADMIN_TOKEN` is explicitly **removed**: *"Token authentication was removed: `BUZZ_ADMIN_TOKEN` is ignored with a startup warning — remove it from the environment."* (`.env.example`)
- The dashboard requires a NIP-07 browser extension (nos2x or Alby) to sign requests — no passwords stored server-side.

For v0 of #36 (Hermes as a member, not as an admin), we don't need the admin dashboard at all. `RELAY_OWNER_PUBKEY` is the env var to set if we want to mark a specific Nostr pubkey as the workspace owner; for a single-operator host-plane deployment, that's the operator's key.

### 5c. Auth on the relay itself

Every WebSocket connection: NIP-42 challenge → signed AUTH event → `AuthState::Authenticated(AuthContext)` → scopes = `Scope::all_known()` (all 14 scopes). Closed-relay mode is the production default: `BUZZ_REQUIRE_AUTH_TOKEN=true`, `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`, `BUZZ_ALLOW_NIP_OA_AUTH=true` (these are the production `.env.example` defaults). HTTP bridge endpoints (`POST /events`, `POST /query`, etc.) use NIP-98.

---

## 6. Upgrade story

### 6a. Image cadence

- Relay lane is **independent** of desktop and mobile (RELEASING.md opens with: *"Buzz has three independent release lanes. Desktop and relay use release PRs. Mobile uses immutable release-candidate tags…"*). This is relevant: a Buzz desktop update does not imply a relay update, and vice versa.
- Desktop release cadence: 4–7 patches/week (looking at the GitHub releases API: `desktop-v0.5.5` → `desktop-v0.5.7` → `desktop-v0.5.8` … up through `desktop-v0.5.20` on 2026-08-26).
- Relay release cadence: `relay-v*` tags are cut when the relay Cargo.toml bumps. `RELEASING.md` is explicit: stable tags update `:latest`; prereleases do not. Every push to `main` still publishes `:main` and `:sha-<7>` rolling tags.
- Maven-style semver with breaking changes bumped in `crates/buzz-relay/Cargo.toml`.

### 6b. Upgrade procedure

For the Compose deployment, upgrading is:

```bash
cd deploy/compose
# 1. pull the image
docker compose pull relay
# 2. (recommended) snapshot Postgres volume + MinIO volume + back up .env
./run.sh backup-hint
# 3. restart — BUZZ_AUTO_MIGRATE=true runs new migrations on first boot
docker compose up -d relay
# 4. validate
./run.sh status
curl -fsS "http://127.0.0.1:${BUZZ_HTTP_PORT}/_liveness"
```

The Compose README is explicit about what must remain stable across restarts:

> *"Keep `BUZZ_RELAY_PRIVATE_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET`, database/Redis, and S3 secrets stable across restarts."*

Losing `BUZZ_RELAY_PRIVATE_KEY` breaks the relay's identity (every relay-signed event from the past becomes unverifiable). Losing the S3 or Postgres credentials means data is unreachable, not lost. So `.env` is the load-bearing artifact.

### 6c. Breaking-change cadence

The project is on a `0.5.x` line (`v0.5.20` latest desktop as of writing, `relay-v` parallel). ARCHITECTURE.md "Known Limitations" lists six verified gaps (no offline query cache, no production rate limiter, no typing REST endpoint, no huddle recording, approval-gate plumbing partial, two workflow actions return `NotImplemented`) — these are *current* gaps, not promises. README is explicit:

> *"Please do not plan your compliance program around the 💭 column yet."*

`VISION.md` and the four vision sub-docs are R&D direction. The README's "Works today / Being wired up / Strong opinions, pending code" table is the only honest maturity signal.

Practical implication: pin to a `relay-v*` tag, not `:main`. Subscribe to release notes on the repo. Don't auto-upgrade — read the relay release PR before bumping.

---

## 7. Public docs and gotchas

### 7a. Primary docs (in priority order)

- [README.md](https://github.com/block/buzz/blob/main/README.md) — orientation, build paths, architecture summary, crate map.
- [ARCHITECTURE.md](https://github.com/block/buzz/blob/main/ARCHITECTURE.md) — single source of truth for kind ranges, event pipeline, crate dependencies, HTTP endpoints, security model, known limitations. **This is the doc.** 510+ lines, dense, current.
- [deploy/compose/README.md](https://github.com/block/buzz/blob/main/deploy/compose/README.md) — production deployment bundle docs (this is the doc that matters for self-host).
- [deploy/compose/.env.example](https://github.com/block/buzz/blob/main/deploy/compose/.env.example) — every production env var with comments.
- [NOSTR.md](https://github.com/block/buzz/blob/main/NOSTR.md) — third-party Nostr client compatibility matrix, NIP coverage.
- [RELEASING.md](https://github.com/block/buzz/blob/main/RELEASING.md) — release lanes, tag taxonomy, signing.
- [VISION.md](https://github.com/block/buzz/blob/main/VISION.md) and the four `VISION_*.md` sub-docs — direction, not commitments.
- [SECURITY.md](https://github.com/block/buzz/blob/main/SECURITY.md) — reporting.
- [engineering.block.xyz/blog/run-your-own-buzz-relay](https://engineering.block.xyz/blog/run-your-own-buzz-relay) — Block's own "how to run your own relay" post (the Railway deploy button links here).
- [GHCR package page](https://github.com/block/buzz/pkgs/container/buzz) — image tags and digests.

### 7b. Gotchas worth flagging for #36

1. **No public-relay federation.** The self-host default is single-relay, single-community. There is no "subscribe to relay X and ingest events" config knob. Hermes's Nostr identity will be visible only to clients connected to *our* relay. This is what #36 wants, but it's worth being explicit: if a future ticket asks Buzz to pull a public Nostr feed, that's a code change, not a config change.
2. **Bundled MinIO is not swappable via `.env` for `virtual`-addressing S3 providers** (e.g. Railway Storage Buckets, real AWS S3 with bucket-as-subdomain). The Compose README says use the Helm chart or a custom Compose fork. We either stay with MinIO or maintain a fork.
3. **Mobile and approval-gate flows are unfinished.** v0 of #36 is text-only, so the 🚧 column (mobile clients, workflow approval gates, push notifications, huddle lifecycle) doesn't bite us yet. But: don't plan a multi-channel production deployment on the strength of the 🚧 column being real.
4. **No production rate limiter.** `RateLimitConfig` defines four tiers (human, agent-standard, agent-elevated, agent-platform); the only implementation is `AlwaysAllowRateLimiter` (a test stub). The relay is not safe to expose to the public internet without a network-layer rate limit (Cloudflare, fail2ban, ingress cap).
5. **`.env` is load-bearing.** It holds `BUZZ_RELAY_PRIVATE_KEY` (relay identity, breaks past relay-signed events if lost), `BUZZ_GIT_HOOK_HMAC_SECRET`, DB/Redis/S3 passwords, and `RELAY_OWNER_PUBKEY`. Back it up first, before any other artifact.
6. **Compose v2.24.4+ required.** The Caddy TLS override uses the `!reset` YAML tag. Ubuntu 22.04's apt ships Compose v2.5; install from Docker's repo or upgrade before applying `compose.caddy.yml`. This is a one-time setup tax but it bites if you `apt install docker-compose` on a fresh VPS.
7. **Identity is a Nostr keypair, not an account.** First admin = generate a keypair, `buzz-admin add-member --pubkey … --role admin`. There is no email confirmation, no password reset. The keypair is the admin. Lose the key, lose the admin; rotate the key by running `add-member` for the new key and `remove-member` for the old.
8. **`releases/` in `block/buzz` is a one-click Railway deploy of the same Compose bundle**, not a separate hosted service for end users. Worth knowing because "Buzz is free, hosted at buzz.xyz" sometimes gets conflated with "you can use the Block-hosted service for free indefinitely." Free is a launch-phase fact; the OSS is the durable thing.
9. **The single-relay self-host model is a deliberate design choice** (see `VISION_SOVEREIGN.md`, `ARCHITECTURE.md` §1). It's not a bug. The map (#36) calls for exactly this shape — "private Nostr relay we run" — so there's no tension. But it's worth being loud in the next ticket that "deploying Buzz" = "deploying one relay we own," not "deploying a Buzz client that talks to relays."
10. **`relay-v*` tags exist and are the right pin** for our host-plane deployment. `:main` is upstream's testing channel. `:latest` updates on stable releases.

---

## Sources

Primary (cited inline above):

- <https://github.com/block/buzz> — repo
- <https://github.com/block/buzz/blob/main/README.md>
- <https://github.com/block/buzz/blob/main/ARCHITECTURE.md>
- <https://github.com/block/buzz/blob/main/RELEASING.md>
- <https://github.com/block/buzz/blob/main/NOSTR.md>
- <https://github.com/block/buzz/blob/main/Cargo.toml>
- <https://github.com/block/buzz/blob/main/deploy/compose/README.md>
- <https://github.com/block/buzz/blob/main/deploy/compose/.env.example>
- <https://github.com/block/buzz/blob/main/deploy/compose/compose.yml>
- <https://github.com/block/buzz/blob/main/deploy/compose/compose.caddy.yml>
- <https://github.com/block/buzz/blob/main/.env.example>
- <https://github.com/block/buzz/tree/main/migrations> — 30 migration files
- <https://github.com/block/buzz/pkgs/container/buzz> — GHCR package page
- <https://engineering.block.xyz/blog/run-your-own-buzz-relay> — Block's hosted-service-side walkthrough

Contextual (used only for framing, not for load-bearing claims):

- <https://www.bitdoze.com/buzz-block-docker-setup> — third-party VPS self-host guide (matches upstream on Postgres 17 / Redis 7 / MinIO / port 3000; called the "no production rate limiter" gap independently)
- <https://www.aibrew.io/blog/block-buzz-complete-guide> — feature maturity table
