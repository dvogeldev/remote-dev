# buzz.dvogeldev.com — Cloudflare Tunnel + Access runbook

Resolves [#53](https://github.com/dvogeldev/remote-dev/issues/53). Parent: [#36](https://github.com/dvogeldev/remote-dev/issues/36). Locks the AFK parts (this repo) and hands you the HITL parts (Cloudflare dashboard + `grr-remote-dev-01` first-run).

## What this gives you

- `https://buzz.dvogeldev.com` (and `wss://buzz.dvogeldev.com`) → `http://127.0.0.1:3000` on `grr-remote-dev-01` (loopback Buzz relay, no public port).
- Cloudflare Access gates the public hostname with the **same OTP + email-allowlist** model `hermes.dvogeldev.com` uses — single-operator identity layer shared across both surfaces.
- `cloudflared-buzz.service` runs as a second systemd --user unit on the host plane (per ADR #0013 — separate tunnel from the Hermes dashboard tunnel, independent rotation + restart boundaries).
- `buzz.service` (per [#47](https://github.com/dvogeldev/remote-dev/issues/47)) is the origin. Relay stays loopback-bound (`127.0.0.1:3000`, `127.0.0.1:8080`, `127.0.0.1:9102`); only the tunnel daemon exposes the public hostname.
- Mobile Buzz clients, second operators on different tailnets, and cross-device operator workflows all work without Tailscale or SSH tunnels.

## Decisions locked (do not reopen lightly)

| | |
|---|---|
| Tunnel name | `buzz-relay` |
| Cloudflare zone | `dvogeldev.com` (same zone as `hermes.dvogeldev.com` — confirm once in Phase 1) |
| Public hostname | `buzz.dvogeldev.com` |
| Origin | `http://127.0.0.1:3000` (loopback, no TLS) |
| Identity provider | One-time PIN (same IdP as `hermes-dvogeldev`) |
| Access policy | Allow `Emails` = `dvogelca@gmail.com`; everyone else blocked. Same allowlist as the Hermes dashboard for v1 single-operator. Split policy the day a second operator joins. |
| Session duration | 24h |
| Auth-required gate | `curl -sI https://buzz.dvogeldev.com/` from a clean laptop must return `HTTP/2 302` redirecting to `/cdn-cgi/access/login` |
| Tunnel unit name | `cloudflared-buzz.service` (separate from `cloudflared.service` which fronts `hermes.dvogeldev.com`) |
| Relay env knob | `BUZZ_PUBLIC_HOSTNAME=buzz.dvogeldev.com` in `~/.buzz/.env` (the toggle that flips the relay's client-facing URLs — media + CORS — from loopback to public hostname; `BUZZ_DOMAIN` + `RELAY_URL` stay loopback) |
| Edge rate limiting | Cloudflare WAF / Rate Limit rule on `buzz.dvogeldev.com` — per-IP throttle on the WS upgrade + HTTP flood rule on `/`. Implemented in this runbook, Phase 1.6. |
| Admin / metrics exposure | `127.0.0.1:8080` (`_liveness`, `_readiness`) and `127.0.0.1:9102` (`/metrics`) stay loopback-only. The tunnel only routes the relay's HTTP port (3000), so admin endpoints are unreachable from the public hostname by construction, not by path allowlist. |

ADR: [0013-buzz-public-hostname-via-cloudflare.md](../docs/adr/0013-buzz-public-hostname-via-cloudflare.md).

## Day-one procedure

### Phase 1 — Provision on Cloudflare (HITL, do these first)

Do these in the Cloudflare Zero Trust dashboard from your laptop. They're the only manual steps in this runbook.

**1.1 Confirm the zone is on this Cloudflare account.**

- [dash.cloudflare.com](https://dash.cloudflare.com) → **Websites** → `dvogeldev.com` listed and active.
- This is the **same zone** `hermes.dvogeldev.com` uses; the first deploy of this runbook is contingent on #35 already having onboarded the zone. If the zone isn't on this account yet, do that part of [#35](https://github.com/dvogeldev/remote-dev/issues/35) first.

**1.2 Confirm the One-time PIN identity provider exists.**

- Zero Trust → **Integrations** → **Identity providers** → One-time PIN should be listed.
- If not (new Zero Trust org), add it. Allowlist `notify.cloudflare.com` on the email gateway so PINs actually arrive.

**1.3 Create the Buzz tunnel + grab the credentials.**

- Zero Trust → **Networks** → **Tunnels** → **Create a tunnel** → name `buzz-relay` → save.
- The dashboard prints an install command; **do not run it** (it would install cloudflared as a system service). Run the local steps below on `grr` instead:

  ```bash
  ssh grr
  # cloudflared binary is installed by scripts/install-cloudflared.sh
  cloudflared tunnel login         # opens browser, you authorize (browser window: pick the dvogeldev.com account)
  cloudflared tunnel create buzz-relay
  # prints: Created tunnel buzz-relay with id eeee-ffff-aaaa-bbbb
  # writes: ~/.cloudflared/eeee-ffff-aaaa-bbbb.json
  ```

- Note the tunnel UUID — it's the `<TUNNEL-UUID>` placeholder in the config below.

**1.4 Add the public hostname.**

- Back in the dashboard, on the `buzz-relay` tunnel → **Routes** tab → **Add route** → **Public hostname**.
  - Subdomain: `buzz`
  - Domain: `dvogeldev.com`
  - Service: `http://127.0.0.1:3000`
- Save. Cloudflare provisions a CNAME for `buzz.dvogeldev.com` → `<UUID>.cfargotunnel.com` automatically; you don't need to add DNS records by hand.

**1.5 Add the Access self-hosted app.**

- Zero Trust → **Access controls** → **Applications** → **Add an application** → **Self-hosted**.
  - Name: `buzz-dvogeldev`
  - Domain: `buzz.dvogeldev.com`
- Next → **Policies** → **Create new policy**:
  - Policy name: `david-ops` (reuse the name from `hermes-dvogeldev` — different app, same allowlist)
  - Action: **Allow**
  - Include: rule type `Emails`, value `dvogelca@gmail.com`
  - Application policies order: `david-ops` Allow, then an **implicit deny** (default — every Access app denies if no Allow matches).
- **Session duration**: 24 hours.
- Save.

**1.6 Add the rate-limit + WAF rules.**

The relay ships only `AlwaysAllowRateLimiter` — every connected client gets unlimited event throughput (per research #38). Without a CF-edge throttle, a single misbehaving client can saturate the relay's accept loop. Two rules, applied in this order:

1. **WAF → Security → WAF → Custom rules → Create rule**:
   - Name: `buzz-edge-flood`
   - Expression: `(http.host eq "buzz.dvogeldev.com" and not cf.client.bot)`
   - Action: **Managed Challenge** (low-friction CAPTCHA challenge, not a hard block)
   - Rate sensitivity: **High**
2. **Security → Events → Rate limit rules → Create rule**:
   - Name: `buzz-relay-ws-throttle`
   - Match: `(http.host eq "buzz.dvogeldev.com")`
   - Rate: 100 requests / 10 seconds per IP
   - Action: **Managed Challenge**
   - Mitigation timeout: 600 seconds

Tune later (the relay's normal traffic is bursty but well under these thresholds). Revisit when there's a second operator.

### Phase 2 — Lay down the config on grr (AFK from your laptop)

**2.1 Enable the public-hostname path in the relay env.**

On `grr`, set `BUZZ_PUBLIC_HOSTNAME` in `~/.buzz/.env`:

```bash
ssh grr '$EDITOR ~/.buzz/.env'
# add or uncomment:
#   BUZZ_PUBLIC_HOSTNAME=buzz.dvogeldev.com
```

`scripts/install-buzz.sh` reads this knob and rewrites the client-facing URLs (`BUZZ_MEDIA_BASE_URL`, `BUZZ_MEDIA_SERVER_DOMAIN`, `BUZZ_CORS_ORIGINS`) to use the public hostname — idempotently, only touching keys whose current value is the loopback placeholder or unset. `BUZZ_DOMAIN` and `RELAY_URL` are deliberately left loopback (see ADR #0013).

**2.2 Re-run `install-buzz.sh` to apply the env rewrite.**

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/install-buzz.sh
```

Stage 4b (added in #53) detects `BUZZ_PUBLIC_HOSTNAME` and rewrites the client-facing URLs. Stage 6 then `docker compose pull`s and restarts the relay container so the new env vars take effect. **No Postgres restore is needed** — the toggle is env-only, not data-changing.

**2.3 Install the cloudflared-buzz unit + config on grr.**

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/install-buzz-cloudflared.sh
```

This writes `~/.config/systemd/user/cloudflared-buzz.service`. It does **not** start the unit yet — that waits for a real `buzz-config.yml`.

**2.4 Drop in the tunnel config.**

On `grr`:

```bash
ssh grr
cp host-plane/cloudflared-buzz-config.yml.example ~/.cloudflared/buzz-config.yml
${EDITOR:-nano} ~/.cloudflared/buzz-config.yml
# replace <TUNNEL-UUID> with the UUID from 1.3
# adjust credentials-file to match the JSON filename
chmod 0600 ~/.cloudflared/buzz-config.yml
```

Keep the `originRequest.httpHostHeader: 127.0.0.1:3000` from the template. The relay's host→community resolver does an exact Host-header match against `BUZZ_DOMAIN=127.0.0.1` (loopback); cloudflared rewrites the incoming `Host: buzz.dvogeldev.com` back to `127.0.0.1:3000` so the relay matches it. Removing this rewrite returns `404 no community is configured for this host`. Client-facing URLs are unaffected — the relay builds them from `BUZZ_MEDIA_BASE_URL` / `BUZZ_MEDIA_SERVER_DOMAIN`.

**2.5 Start the tunnel.**

```bash
HOST=grr ./scripts/install-buzz-cloudflared.sh --start
# or manually:
ssh grr 'systemctl --user enable --now cloudflared-buzz.service'
```

Verify on `grr`:

```bash
ssh grr 'journalctl --user -u cloudflared-buzz.service -n 40'
# expect: "Registered tunnel connection" and "Route via CNAME" lines within 30s
```

### Phase 3 — Verify

**3.1 From grr, the relay itself (loopback, the canonical health path).**

```bash
ssh grr 'curl -fsS http://127.0.0.1:8080/_liveness'
# expect: ok

ssh grr 'cd ~/.buzz && docker compose logs --tail=40 relay | grep -i buzz_domain'
# expect: BUZZ_DOMAIN=127.0.0.1 in the log line (loopback is correct; the
# tunnel rewrites the Host header back to loopback — see ADR #0013)
```

**3.2 From your laptop on a non-tailnet network, the public hostname.**

```bash
curl -sI https://buzz.dvogeldev.com/ | head -n 1
# expect: HTTP/2 302

curl -sI https://buzz.dvogeldev.com/ | grep -i location
# expect: Location: https://dvogeldev.cloudflareaccess.com/...  (CF Access OTP wall)
```

`HTTP/2 302` to a Cloudflare Access URL is the official done gate — proves the tunnel is up, the public hostname resolves, and CF Access is gating the path. After OTP sign-in, the same URL serves the relay's HTTP frontend.

**3.3 Sign in once in a browser.**

- Open `https://buzz.dvogeldev.com` on a coffee-shop-wifi laptop (or use a phone on cellular — that's the whole point of the public hostname).
- CF Access bounces to `/cdn-cgi/access/login`. Enter `dvogelca@gmail.com`; check inbox for the PIN; paste it in.
- You land on the Buzz desktop's web view (if you used the Buzz desktop AppImage) or — for a pure-browser operator — the relay's index page.

**3.4 Connect a Buzz client via `wss://buzz.dvogeldev.com`.**

In the Buzz desktop client's connection settings:

- **Server URL**: `wss://buzz.dvogeldev.com`
- **Account**: your Nostr nsec (the operator's, whose pubkey is in `RELAY_OWNER_PUBKEY`)

The client opens a WebSocket → CF Access terminates the HTTP upgrade and challenges for OTP → after OTP, the tunnel proxies the WS to `127.0.0.1:3000` on `grr`, rewriting the Host header back to `127.0.0.1:3000` → the relay's host→community resolver matches it against `BUZZ_DOMAIN=127.0.0.1` → the WS proceeds → NIP-42 AUTH from the desktop client → you're in.

**3.5 Smoke from the laptop.**

```bash
HOST=grr ./scripts/smoke-buzz.sh
```

The fifth check (`[5/5] public-hostname end-to-end`) probes `https://buzz.dvogeldev.com/` and expects a 302 to CF Access login. Steps 1–4 still run as before.

**3.6 Multi-device verification (the v1 reason this exists).**

- A second operator on a different Tailscale, signing in with `wss://buzz.dvogeldev.com`, reaches the same workspace as the primary operator.
- A phone with the Buzz mobile app, pointed at `wss://buzz.dvogeldev.com`, reaches the workspace over cellular (no Tailscale, no SSH).
- The operator's laptop browser at `https://buzz.dvogeldev.com` reaches the same workspace.

## Operating

### Add a second identity

- Zero Trust → **Access controls** → **Applications** → `buzz-dvogeldev` → **Policies** → `david-ops` → edit → add the email under **Include** → save. Takes effect on next login.
- The second identity also needs to be a relay member (`docker compose exec relay buzz-admin add-member --pubkey <their-hex> --role admin`).

### Why gmail instead of david@dvogeldev.com

The original plan in [#31](https://github.com/dvogeldev/remote-dev/issues/31) was to allowlist `david@dvogeldev.com`. As of first deploy (2026-09-01), email hosting for `dvogeldev.com` isn't delivering Cloudflare Access OTPs to that address — so the allowlist is `dvogelca@gmail.com` (the operator's working alias). Same allowlist logic as `hermes.dvogeldev.com` for v1 single-operator; split policy the day a second operator joins and their allowlist differs. See `servers/hermes-dvogeldev-access.md` "Why gmail" for the broader context.

### Rotate the tunnel token

- On `grr`: `cloudflared tunnel rotate credentials buzz-relay --cred-file ~/.cloudflared/<UUID>.json` (writes a fresh JSON, the old one stops working).
- No restart needed; `cloudflared` hot-reloads.

### After a relay upgrade

- `cd ~/.buzz && docker compose pull relay && systemctl --user restart buzz.service` restarts the relay container. The tunnel (`cloudflared-buzz.service`) is unaffected — it just keeps proxying whatever listens on `127.0.0.1:3000`.

### Revert to loopback-only mode

If the public hostname needs to come down (CF Access outage, abuse investigation):

```bash
ssh grr
${EDITOR:-nano} ~/.buzz/.env
# comment out: BUZZ_PUBLIC_HOSTNAME=buzz.dvogeldev.com
# restore the loopback defaults (install-buzz.sh will rewrite them on next run):
#   BUZZ_MEDIA_BASE_URL=http://127.0.0.1:3000/media
#   BUZZ_MEDIA_SERVER_DOMAIN=127.0.0.1
#   BUZZ_CORS_ORIGINS=http://127.0.0.1:3000
#   (BUZZ_DOMAIN and RELAY_URL are already loopback — leave them)
HOST=grr /path/to/remote-dev/scripts/install-buzz.sh      # rewrites + restarts relay
systemctl --user stop cloudflared-buzz.service            # tunnel down, public hostname returns DNS NXDOMAIN/CF 1033
```

Operators can still reach the relay via Tailscale or SSH tunnel — that path is unchanged.

### Update cloudflared

- `cloudflared` self-updates by default; both units run with `--no-autoupdate` to keep that off the critical path. To upgrade manually: download a fresh binary to `~/.local/bin/cloudflared` and `systemctl --user restart cloudflared.service cloudflared-buzz.service`.

### Restart loops / flaps

- `journalctl --user -u cloudflared-buzz.service -n 200` — `cloudflared` logs to journal; missing/bad config is the usual cause. The "skip start" logic in `install-buzz-cloudflared.sh` keeps the unit down until `~/.cloudflared/buzz-config.yml` has a real tunnel UUID.
- 302 from CF Access flipping to 200 from off-LAN: the Access app isn't matching, or the policy was deleted. Re-check Zero Trust → Access controls → Applications.

### Backups

- `~/.cloudflared/buzz-config.yml` and the credentials JSON — back these up (they're in the `~/.cloudflared` tree). The tunnel itself, the Access app, and the rate-limit rules live in Cloudflare and don't need local backup.
- Re-creating the tunnel is `cloudflared tunnel create buzz-relay` + the same config — both can be rebuilt from this runbook + `host-plane/cloudflared-buzz-config.yml.example`.

## Files in this repo

| Path | What |
|---|---|
| `host-plane/cloudflared-buzz.service` | systemd --user unit for the Buzz tunnel. `After=buzz.service` so the relay is up before the tunnel tries to reach it. |
| `host-plane/cloudflared-buzz-config.yml.example` | Tunnel config template. Replace `<TUNNEL-UUID>`, copy to `~/.cloudflared/buzz-config.yml`. |
| `scripts/install-buzz-cloudflared.sh` | AFK install of the Buzz tunnel unit on grr. Use `--start` after the config is in place. |
| `scripts/install-buzz.sh` | Stage 4b detects `BUZZ_PUBLIC_HOSTNAME` and rewrites the client-facing URLs (media + CORS); idempotent. |
| `scripts/provision-buzz-access.sh` | Creates the `buzz-dvogeldev` CF Access app via the API, reusing the account-level OTP IdP + `david-ops` policy; ensures the DNS CNAME. |
| `scripts/smoke-buzz.sh` | Fifth check probes `https://<BUZZ_PUBLIC_HOSTNAME>/` and expects a 302 to CF Access. |
| `host-plane/buzz/.env.example` | Documents the `BUZZ_PUBLIC_HOSTNAME` opt-in knob. |
| `docs/adr/0013-buzz-public-hostname-via-cloudflare.md` | Locks the two-tunnel shape and the public-hostname env rewrite. |

## Out of scope

- `hermes.dvogeldev.com`'s tunnel — separate ticket #35; this ticket deliberately uses a second tunnel rather than widening the first.
- Running `cloudflared` as a system service — `host-plane/cloudflared-buzz.service` is a systemd --user unit, matching the standing host-plane pattern in `CONTEXT.md`.
- A second identity — day one is single-operator per [#31](https://github.com/dvogeldev/remote-dev/issues/31). The allowlist widens the day a second operator joins.
- A NIP-05 verified handle on the relay — deferred; reserved for the day a second operator needs a per-pubkey allowlist visible at the relay layer instead of operator-edited env vars.
- Production observability for Buzz (Postgres, Redis, MinIO, relay logs) and the Hermes `buzz` plugin (logs, metrics, alerts) — out of scope for this ticket; covered by the map's "Not yet specified" list.
- Multi-relay / multi-community mode — single-community self-host is the v1 shape per ADR #0011.
- Mobile push notifications for Buzz mobile — out; that's an app-level concern, not a transport one. Once the client has `wss://buzz.dvogeldev.com`, mobile push is the app's own plumbing.

## Done means

- `curl -sI https://buzz.dvogeldev.com/` from a clean laptop returns `HTTP/2 302` to a CF Access URL (the official done gate — proves tunnel + Access app are up).
- `curl -fsS http://127.0.0.1:8080/_liveness` on `grr` returns `ok` (the canonical relay health check, unchanged from #47).
- `BUZZ_PUBLIC_HOSTNAME=buzz.dvogeldev.com` is in `~/.buzz/.env` on `grr`, and `BUZZ_MEDIA_BASE_URL=https://buzz.dvogeldev.com/media` / `BUZZ_MEDIA_SERVER_DOMAIN=buzz.dvogeldev.com` / `BUZZ_CORS_ORIGINS=https://buzz.dvogeldev.com` are set (by `install-buzz.sh` Stage 4b). `BUZZ_DOMAIN` and `RELAY_URL` stay loopback.
- A second operator on a different tailnet can sign in to `wss://buzz.dvogeldev.com` via CF Access OTP and reach the same workspace as the primary operator.
- `scripts/smoke-buzz.sh` runs all five checks cleanly from a non-tailnet laptop.
- No public port is open on `grr` for 3000 / 8080 / 9102 (only 22/SSH and the tunnel).
- This runbook is committed and linked from [#53](https://github.com/dvogeldev/remote-dev/issues/53).
