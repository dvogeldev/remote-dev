# Nostr relay implementations: strfry vs nostr-rs-relay vs Khatru

> Resolves [#39](https://github.com/dvogeldev/remote-dev/issues/39).
> Parent: [#36](https://github.com/dvogeldev/remote-dev/issues/36) (Hermes ↔ Buzz channel map).
> Pick is intentionally **not** made here — the G1 ticket ("Pick the Nostr relay implementation") owns that.
> Sources cited inline. All claims trace to a primary doc page, the upstream GitHub repo, or `gh api`/`webfetch` snapshots taken 2026-09-01.

## TL;DR

| Dimension | strfry | nostr-rs-relay | Khatru |
| --- | --- | --- | --- |
| Language / runtime | C++ (single binary, statically linkable) | Rust (single binary) | Go **library** (you write `main.go`) |
| License | GPL-3.0 | MIT | Unlicense |
| Stars / forks | 718 / 168 | 714 / 196 | 139 / 36 |
| Persistence engine | LMDB (memory-mapped, embedded) | SQLite (embedded); experimental PostgreSQL | Pluggable via `eventstore` (BoltDB, LMDB, SQLite, …) — you wire it |
| Default listener | `:7777` | `:8080` (container exposes 8080) | `:3334` in the docs example — *you set it* |
| NIP coverage (relay-relevant) | 1, 2, 4, 9, 11, 22, 28, 33, 40, 42, 45, 70, 77 + negentropy/NIP-77 | 1, 2, 5, 9, 11, 12, 15, 16, 20, 22, 28, 33, 40, 42, 91 | Whatever you implement; framework supports NIP-42 + NIP-86 Management API out of the box |
| Write policy | Default = anyone; gate via external `writePolicy.plugin` (Node script) | Default = anyone; gate via `pubkey_whitelist` and/or NIP-05 `verified_users` in `config.toml` | You write `relay.RejectEvent` / `RejectFilter` Go funcs — arbitrary logic, including pubkey allowlists |
| Auth / pubkey allowlist | Native NIP-42 challenge (`relay.auth.serviceUrl`); pubkey gating requires writing a plugin (~few dozen lines of Node) | Native NIP-42 (`authorization` section) + first-class `pubkey_whitelist` array in `config.toml` | NIP-42 supported via framework helper; pubkey allowlist is a one-line `RejectEvent` closure |
| Maintenance health | **Very active.** Last commit `2026-08-28` ("bump golpe"). `master` at 1.1.2 in `CHANGES`. 30 open issues. | **Active but slower.** Last commit `2026-05-22`. Tag `0.10.0` on sourcehut ~3 months old. 65 open issues. | **Archived.** Repo `archived: true`, banner dated `2026-01-24`. Last commit `2025-09-22`. 5 open issues. Successor pointed at by the maintainer: `fiatjaf.com/nostr/khatru` (new import path). |
| Container image | Official `Dockerfile` + multi-arch image at `ghcr.io/hoytech/strfry` (last published `2026-08-28`) | Official `Dockerfile` + `scsibug/nostr-rs-relay` on Docker Hub (48.1 MB, last updated ~3 months ago) | **No official image.** You `go build` yourself or maintain a `Dockerfile` in our repo. |
| Backup story | `strfry export` → JSONL (`--fried` for fast re-import); `strfry compact` for LMDB reclamation. Single directory is the whole DB. | Copy the SQLite file; standard `.backup`/snapshot tooling works. Single file plus optional `index.html`. | Depends on the `eventstore` backend you wire. BoltDB/LMDB = directory; SQLite = file. |
| Operational extras | Prometheus `/metrics`, negentropy sync, hot-reload config, zero-downtime restart via `REUSE_PORT` + `SIGUSR1` | Rate limits, message size limits, broadcast/event buffer sizes — all in `config.toml` | NIP-86 management API (if you wire handlers); arbitrary HTTP handlers (mux in); log to stderr |
| Footprint at low traffic | LMDB is mmap-based — RSS tracks working set, not total DB size; documented as "Low memory usage" | SQLite is heavier than LMDB for very small workloads but still comfortably runs on a Pi; project goal is "small VPSes / Raspberry Pi" | Compiled Go binary is small (single static binary); runtime footprint dominated by whichever store you pick |
| Compile-from-source cost | Heavy: needs `lmdb`, `flatbuffers`, `secp256k1`, `zstd`, `libuv`, `perl`, plus the bundled `golpe` tool | Medium: `cargo build -r`, plus `protobuf-compiler` / `libssl-dev` | Light: `go build` |

---

## 1. strfry (`hoytech/strfry`)

Source: <https://github.com/hoytech/strfry>, `CHANGES` file at <https://github.com/hoytech/strfry/blob/master/CHANGES>, `gh api repos/hoytech/strfry` (2026-09-01), `gh api users/hoytech/packages?package_type=container` (2026-09-01).

### Footprint / persistence
- "No external database required: All data is stored locally on the filesystem in LMDB" — README.
- LMDB is memory-mapped; the `data.mdb` file is the entire DB. RSS at low traffic is roughly the working set, not the file size. The project is widely recommended for small VPSes and ships in Umbrel's app store ([D-Central guide, 2026-03-07](https://d-central.tech/run-your-own-nostr-relay-bitcoiners)).
- `gh api` snapshot: `stargazers_count=718`, `open_issues_count=30`, `pushed_at=2026-08-28`, `language=C++`, `license=GPL-3.0`.

### Write policy / auth
- Default: anyone can write. Gating is delegated to a `writePolicy.plugin` — an executable that strfry spawns and pipes events into. The community plugin ecosystem (e.g. `Michilis/Strfry-plugins`) covers pubkey allowlists, NIP-05 allowlists, rate limiters, and spam filters.
- NIP-42 AUTH is native. To activate: set `relay.auth.serviceUrl` (must be the public `wss://…` URL) — when a protected event arrives, strfry issues an `AUTH` challenge and only accepts after a valid `kind 22242` response (`CHANGES[1.1.0]`).
- Plugins receive the authenticated pubkey via the `authed` field, so a pubkey allowlist plugin reads cleanly off `event.pubkey`.

### Maintenance
- `pushed_at=2026-08-28`. Most recent commit `bump golpe`. `CHANGES` tops out at 1.1.2; the last several entries are security-relevant (e.g. `1.1.2`: "Fix a memory DoS in uWebSockets where an attacker can continue appending websocket fragments under the max payload size"). No GitHub "Releases" page is used — `CHANGES` is the source of truth.
- 30 open issues, 19 open PRs (visible on the repo sidebar).
- Negentropy sync (NIP-77) is implemented in C++ and shipped in-tree; this is unique among the three and useful if the host plane wants to mirror to/from other relays.

### Container
- Official `Dockerfile` + `arch.Dockerfile` in repo. Published image at `ghcr.io/hoytech/strfry` — `updated_at=2026-08-28` (`gh api users/hoytech/packages?package_type=container`).
- A Docker Hub image at `hub.docker.com/r/hoytech/strfry` is referenced in third-party guides but was unreachable on 2026-09-01; the ghcr.io image is the canonical one.

### Backup / ops
- `strfry export` → JSONL. `strfry export --fried` packs precomputed hashes for 10× faster re-import on another relay (or an upgraded DB version — the upgrade procedure for incompatible DB versions is exactly this export/re-import).
- `strfry compact` reclaims LMDB fragmentation (requires a restart for size reclamation; not required for cross-host migration).
- `strfry router` is bundled for mesh/mirror topologies — relevant if we later want to mirror events to a backup host.

### Footgun worth flagging
- GPL-3.0. Anyone redistributing a modified binary has to ship source. For a self-hosted internal tool on our own infra this is a non-issue; it would matter if we ever shipped a packaged image to third parties.

---

## 2. nostr-rs-relay (`scsibug/nostr-rs-relay`, canonical `~gheartsfield/nostr-rs-relay` on sourcehut)

Source: <https://sr.ht/~gheartsfield/nostr-rs-relay/>, <https://github.com/scsibug/nostr-rs-relay>, <https://hub.docker.com/r/scsibug/nostr-rs-relay>, `gh api repos/scsibug/nostr-rs-relay` (2026-09-01).

### Footprint / persistence
- SQLite by default; PostgreSQL experimental. SQLite is a single `nostr.db` file in a configurable directory.
- Design goal stated in the README: "Suitable for running on small VPSes or other resource-constrained devices like a RaspberryPi." ([sourcehut](https://sr.ht/~gheartsfield/nostr-rs-relay/)).
- `gh api` snapshot: `stargazers_count=714`, `open_issues_count=65`, `pushed_at=2026-05-22`, `language=Rust`, `license=MIT`.

### Write policy / auth
- Native `pubkey_whitelist` in `config.toml` — an array of allowed hex pubkeys. This is the only one of the three with a config-file allowlist, no plugin required. The "verified_users" section also supports NIP-05-based gating with `verify_expiration_hours` (Nostr Dev Guide "Relay Configuration", 2026).
- NIP-42 (`authorization` section in `config.toml`) is supported.
- Rate limiting, message-size limits, and subscription limits are all `config.toml`-tunable.

### Maintenance
- `pushed_at=2026-05-22`. Latest commit "docs: NIP-91 implemented" (NIP-91 AND-operator for filters added in the same window as tag `0.10.0`).
- Tag `0.10.0` was the active "testing" tag on Docker Hub; `0.9.0` was the "stable" tag. Docker Hub page shows image last updated "3 months ago" — i.e. ~June 2026.
- 65 open issues is roughly 2× strfry's count — keep an eye on whether they're being triaged.
- Canonical issue tracker is on sourcehut (`~gheartsfield/nostr-rs-relay`); GitHub is a mirror.

### Container
- `scsibug/nostr-rs-relay` on Docker Hub, 48.1 MB. Sample config supports rootless podman via `--user=100:100` with bind-mounted `data` and `config.toml` (README).

### Backup / ops
- Single SQLite file: `cp nostr.db backup.db`, or use SQLite's online backup API. This is the lowest-friction backup story of the three — file-level snapshots, well-understood restore semantics.
- MIT licensed — no source-disclosure obligation on redistribution.

---

## 3. Khatru (`fiatjaf/khatru`)

Source: <https://github.com/fiatjaf/khatru>, <https://khatru.nostr.technology/getting-started>, `gh api repos/fiatjaf/khatru` (2026-09-01).

### Footprint / persistence
- It's a Go library, not a relay binary. To get a relay, you write a `main.go` that imports `fiatjaf.com/nostr/khatru` and an `eventstore` backend (BoltDB, LMDB, SQLite), wire `StoreEvent`/`QueryEvents`/`DeleteEvent`, and call `relay.Start(...)`. Storage backend is your choice — the closest match for strfry is the LMDB `eventstore` adapter.
- The "7 lines of code" sample uses `boltdb.BoltBackend{Path: "/tmp/khatru-bolt-tmp"}` — BoltDB is a single-file embedded KV store, comparable in spirit to LMDB but BTree-based.

### Write policy / auth
- The framework's headline feature: every policy hook is a slice of Go functions. `relay.RejectEvent` and `relay.RejectFilter` are append-to slices, so you compose policies like middleware. A pubkey allowlist is literally one closure comparing `event.PubKey` to a `map[PubKey]struct{}` of allowed keys.
- NIP-42 AUTH is supported via the framework helper: rejecting with `"auth-required: <reason>"` causes the relay to issue a challenge automatically (`RejectFilter` example in the README).
- NIP-86 Management API is also built in — you write handlers per RPC call.

### Maintenance
- **Archived.** `gh api repos/fiatjaf/khatru` returns `"archived": true`. The archived banner on the repo page is dated 2026-01-24.
- Last commit `2025-09-22` ("add notice about the new library"). The new library is at `fiatjaf.com/nostr/khatru` (per `pkg.go.dev/fiatjaf.com/nostr/khatru`) — the README's opening line tells readers to look there. That new library has not been audited here and would need its own pass.
- 5 open issues. 139 stars, 36 forks — by far the smallest community of the three.

### Container
- No official image. There are community images (e.g. from `khatru.nostrver.se`), but they are not maintained by the project.

### Backup / ops
- Whatever your `eventstore` backend is — BoltDB file, LMDB directory, SQLite file. The framework doesn't add a backup layer of its own.

---

## 4. Cross-cutting observations

### Footprint at low traffic (Hermes ↔ Buzz channel assumptions)
For a single-internal-user, low-throughput channel — a handful of clients, hand-curated pubkeys, modest message volume — all three are operationally fine. The differences show up in the secondary axes:

- **strfry** is the only one that is *also* happy at very high traffic; we're paying nothing for that headroom at low traffic except a slightly heavier build toolchain.
- **nostr-rs-relay** is the only one whose config file directly expresses "allowlist these pubkeys" without writing code or plugins — a meaningful operational ergonomic win for a closed relay.
- **Khatru** is the only one where "write a few lines of Go" is the answer to almost every question. That's a feature when you need it and a tax when you don't.

### Auth / allowlist (the "restrict to our own pubkeys" question)
| Implementation | How to restrict to our pubkeys |
| --- | --- |
| strfry | Native NIP-42 challenge *for* clients; gating the relay on pubkey requires writing (or installing) a `writePolicy.plugin` |
| nostr-rs-relay | Native `pubkey_whitelist = ["…", "…"]` in `config.toml`; NIP-42 also available |
| Khatru | Native: one `RejectEvent` closure that compares `event.PubKey` to an in-memory set; NIP-42 via `khatru.GetAuthed(ctx)` |

If "pubkey allowlist with zero custom code" is the dominant criterion, **nostr-rs-relay** wins on raw configuration ergonomics. If we're comfortable with a small amount of Go, **Khatru** is comparable and gives more policy composition. **strfry** requires either a community plugin or ~50 lines of Node.

### Maintenance risk
strfry is the only one of the three with commits in the last week. nostr-rs-relay is the slowest-moving but still maintained. **Khatru is archived** — anyone picking it today is signing up to own the migration to the successor library or fork it. That alone is a material operational risk for a host-plane service.

### Container image availability
- strfry: `ghcr.io/hoytech/strfry` (canonical, fresh).
- nostr-rs-relay: `scsibug/nostr-rs-relay` on Docker Hub (fresh, official).
- Khatru: no official image. Must be built in-repo.

---

## 5. Recommendation (research-side, not the G1 pick)

*This is a research note, not the winner. The G1 ticket decides.*

If the downstream criterion is "least custom code to stand up a pubkey-gated relay that we can forget about," the trade-off profile favors **nostr-rs-relay** for *today*: native `pubkey_whitelist`, MIT license, official Docker image, SQLite backup is a single file copy. Its slower release cadence and 65-issue backlog are the cost.

If the downstream criterion is "longest runway / most headroom and active development," **strfry** is clearly ahead: daily-level commits, negentropy sync, Prometheus metrics, hot-reload config, zero-downtime restarts. Its only friction is the config-file allowlist is plugin-shaped (we'd ship a 30-line plugin script and call it done).

If the downstream criterion is "absolute control over every policy decision and we're happy in Go," **Khatru** has the cleanest composition model — but the archived-repo status is a showstopper for a host-plane service that has to outlive this project. The successor library at `fiatjaf.com/nostr/khatru` would need its own audit before adoption.

---

## Appendix A — verification commands run on 2026-09-01

```
gh api repos/hoytech/strfry               → pushed_at=2026-08-28, open_issues=30, 718 stars
gh api repos/scsibug/nostr-rs-relay      → pushed_at=2026-05-22, open_issues=65, 714 stars
gh api repos/fiatjaf/khatru              → archived=true,  pushed_at=2025-09-22, 139 stars, 5 open issues
gh api users/hoytech/packages?package_type=container → ghcr.io/hoytech/strfry updated 2026-08-28
hub.docker.com/r/scsibug/nostr-rs-relay  → 48.1 MB, last updated ~3 months ago
```

Raw notes and query transcripts preserved in this conversation's tool history.