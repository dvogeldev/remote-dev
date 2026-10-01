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
| `host-plane/buzz/.env.example` | Env template; copy to `~/.buzz/.env` on grr. Documents the `BUZZ_PUBLIC_HOSTNAME` opt-in for the public-hostname path (#53). |
| `host-plane/buzz.service` | systemd --user unit driving `docker compose up`. |
| `host-plane/cloudflared-buzz.service` | systemd --user unit for the Buzz tunnel (#53). `After=buzz.service` so the relay is up before the tunnel tries to reach it. |
| `host-plane/cloudflared-buzz-config.yml.example` | Tunnel config template for `buzz.dvogeldev.com` (#53). |
| `scripts/install-buzz.sh` | AFK install on grr. Re-run to rotate secrets / push the relay keypair. Detects existing `pass buzz/relay/private-key` and reuses it (recovery story, ADR #0012); detects latest Postgres dump in `pass buzz/postgres-dumps/` and restores before bringing the relay up (#51); Stage 4b detects `BUZZ_PUBLIC_HOSTNAME` and rewrites the client-facing URLs (#53). |
| `scripts/install-buzz-cloudflared.sh` | AFK install of the Buzz tunnel unit on grr (#53). Use `--start` after the config is in place. |
| `scripts/enable-hermes-buzz.sh` | Installs the real `buzz` CLI from the desktop AppImage; idempotently configures `~/.hermes/.env` (preserves existing `BUZZ_HOME_CHANNEL` / `BUZZ_CHANNELS` / `BUZZ_ALLOWED_USERS` on re-run); runs `hermes gateway install` + start. |
| `scripts/smoke-buzz.sh` | Five-check smoke test (liveness, NIP-42 from inside the container, round-trip over SSH tunnel, public-hostname end-to-end via CF Access). The fifth check is opt-in via `BUZZ_PUBLIC_HOSTNAME` (#53). |
| `scripts/prune-buzz-pg-dumps.sh` | 90-day retention prune for `pass buzz/postgres-dumps/` (#52, ADR #0012 Q9). Integrated into the Postgres backup procedure; idempotent; override `BUZZ_PG_DUMPS_RETENTION_DAYS` to tune. |
| `docs/adr/0011-buzz-host-plane-layout.md` | Loopback bind, vendoring policy, system unit shape. |
| `docs/adr/0012-keypair-rotation-and-backup.md` | Rotation triggers + backup cadence + recovery story for both keypairs. |
| `docs/adr/0013-buzz-public-hostname-via-cloudflare.md` | Locks the two-tunnel shape and the public-hostname env rewrite (#53). |
| `servers/buzz-dvogeldev-access.md` | Public-hostname runbook: CF Access app, tunnel token issuance, rate-limit rules, smoke-test extension (#53). |

## Out of scope

- `cloudflared`-fronted exposure of Buzz — implemented in
  [servers/buzz-dvogeldev-access.md](buzz-dvogeldev-access.md)
  ([#53](https://github.com/dvogeldev/remote-dev/issues/53)). This runbook
  covers the loopback-only posture; the public-hostname path is opt-in via
  `BUZZ_PUBLIC_HOSTNAME` in `~/.buzz/.env`.
- TLS via the upstream `compose.caddy.yml` override. Operator reaches the
  relay through Tailscale or SSH; no public TLS.
- Multi-relay / multi-community mode. The single-host, single-relay,
  single-community self-host default is the v0 shape per ADR #0011.
