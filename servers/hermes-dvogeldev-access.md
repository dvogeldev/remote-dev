# hermes.dvogeldev.com — Cloudflare Tunnel + Access runbook

Resolves [#35](https://github.com/dvogeldev/remote-dev/issues/35). Locks the AFK parts (this repo) and hands you the HITL parts (Cloudflare dashboard + `grr-remote-dev-01` first-run).

## What this gives you

- `https://hermes.dvogeldev.com` → `http://127.0.0.1:9119` on `grr-remote-dev-01` (loopback Hermes dashboard, no public port).
- Cloudflare Access gates it with **email allowlist + one-time PIN** (no IdP).
- `cloudflared` runs as a systemd --user unit on the host plane (per `CONTEXT.md`).
- `hermes-dashboard.service` (per [#30](https://github.com/dvogeldev/remote-dev/issues/30)) is the origin. `HERMES_DASHBOARD_PUBLIC_URL=https://hermes.dvogeldev.com` is inline in the unit so Chat's PTY websocket Origin is accepted; Hermes basic auth (from `~/.hermes/.env`) satisfies the fail-closed gate that public_url engages. Cloudflare Access is still the public hostname gate.

## Decisions locked (do not reopen lightly)

| | |
|---|---|
| Tunnel name | `hermes-gui` |
| Cloudflare zone | `dvogeldev.com` (verify it's on this account first) |
| Public hostname | `hermes.dvogeldev.com` |
| Origin | `http://127.0.0.1:9119` (loopback, no TLS) |
| Identity provider | One-time PIN (no Google/GitHub/Nous OAuth) |
| Access policy | Allow `Emails` = `dvogelca@gmail.com`; everyone else blocked |
| Session duration | 24h |
| Auth-required gate | `curl -fsS https://hermes.dvogeldev.com/api/status \| jq '.auth_required'` must return `true` |

## Day-one procedure

### Phase 1 — Provision on Cloudflare (HITL, do these first)

Do these in the Cloudflare Zero Trust dashboard from your laptop. They're the only manual steps in this runbook.

**1.1 Confirm the zone is on this Cloudflare account.**

- [dash.cloudflare.com](https://dash.cloudflare.com) → **Websites** → `dvogeldev.com` listed and active.
- If it's not on this account, stop. The DNS zone needs to be moved to a CF account you control before the tunnel can route `hermes.dvogeldev.com`.

**1.2 Add the One-time PIN identity provider.**

- Zero Trust → **Integrations** → **Identity providers** → **Add new** → **One-time PIN** → save.
- New Zero Trust orgs use Cloudflare IdP as the default; OTP is no longer auto-added.
- Allowlist `notify.cloudflare.com` / `noreply@notify.cloudflare.com` on your email gateway per the docs so the PIN actually arrives.

**1.3 Create the tunnel + grab the credentials.**

- Zero Trust → **Networks** → **Tunnels** → **Create a tunnel** → name `hermes-gui` → save.
- The dashboard prints an install command; do **not** run it (it would install cloudflared as a system service). Instead, run the local steps below on `grr`:

  ```bash
  ssh grr
  # cloudflared binary is installed by scripts/install-cloudflared.sh
  cloudflared tunnel login         # opens browser, you authorize
  cloudflared tunnel create hermes-gui
  # prints: Created tunnel hermes-gui with id aaaa-bbbb-cccc-dddd
  # writes: ~/.cloudflared/aaaa-bbbb-cccc-dddd.json
  ```

- Note the tunnel UUID — it's the `<TUNNEL-UUID>` placeholder in the config below.

**1.4 Add the public hostname.**

- Back in the dashboard, on the tunnel → **Routes** tab → **Add route** → **Public hostname**.
  - Subdomain: `hermes`
  - Domain: `dvogeldev.com`
  - Service: `http://127.0.0.1:9119`
- Save. Cloudflare provisions a CNAME for `hermes.dvogeldev.com` → `<UUID>.cfargotunnel.com` automatically; you don't need to add DNS records by hand.

**1.5 Add the Access self-hosted app.**

- Zero Trust → **Access controls** → **Applications** → **Add an application** → **Self-hosted**.
  - Name: `hermes-dvogeldev`
  - Domain: `hermes.dvogeldev.com`
- Next → **Policies** → **Create new policy**:
  - Policy name: `david-ops`
  - Action: **Allow**
  - Include: rule type `Emails`, value `<your-email-here>` (use your real allowlist email)
  - Application policies order: `david-ops` Allow, then an **implicit deny** (default — every Access app denies if no Allow matches).
- **Session duration**: 24 hours.
- Save.

### Phase 2 — Lay down the config on grr (AFK from your laptop)

**2.1 Install cloudflared and the user-unit on grr.**

From your laptop:

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/install-cloudflared.sh
```

This downloads `cloudflared` to `~/.local/bin/cloudflared`, writes `~/.config/systemd/user/cloudflared.service`, and creates `~/.cloudflared/`. It does **not** start the unit yet — that waits for a real config.

**2.2 Drop in the tunnel config.**

On grr:

```bash
cp host-plane/cloudflared-config.yml.example ~/.cloudflared/config.yml
${EDITOR:-nano} ~/.cloudflared/config.yml
# replace <TUNNEL-UUID> with the UUID from 1.3
# adjust credentials-file to match the JSON filename
chmod 0600 ~/.cloudflared/config.yml
```

Leave Host as `hermes.dvogeldev.com`. The dashboard unit sets `HERMES_DASHBOARD_PUBLIC_URL=https://hermes.dvogeldev.com`, which adds that hostname to the HTTP Host **and** WebSocket Origin allowlist. Rewriting Host to `127.0.0.1` lets REST through but Chat still sends `Origin: https://hermes.dvogeldev.com` and Hermes refuses the PTY upgrade (`origin_mismatch` → browser WS close 1006). CF Access remains the public gate; Hermes basic auth is the in-process provider the fail-closed gate requires once `public_url` is set. Unwrap `hermes/dashboard/BASIC_AUTH_*` with `scripts/unwrap-hermes-env.sh`.

**2.3 Start the tunnel.**

```bash
HOST=grr ./scripts/install-cloudflared.sh --start
# or manually:
ssh grr 'systemctl --user enable --now cloudflared.service'
```

### Phase 3 — Verify

**3.1 From grr, the dashboard itself.**

```bash
curl -fsS http://127.0.0.1:9119/api/status | jq .
```

Expect version, gateway state, `auth_required: true` (public_url engages the gate even on loopback), `"basic"` in `auth_providers`, active session count, memory + disk pressure.

**3.2 From your laptop on a non-tailnet network, the public hostname.**

```bash
curl -sI https://hermes.dvogeldev.com | head -n 1
# expect: HTTP/2 302

curl -fsS https://hermes.dvogeldev.com/api/status | jq '.auth_required, .auth_providers'
# expect: true    <-- this is the official done gate
# and "basic" in auth_providers
```

`auth_required: true` is what the Hermes docs require before Chat's websocket is allowed. Loopback now reports it too, because `HERMES_DASHBOARD_PUBLIC_URL` is set. CF Access still sits in front; after the OTP you also sign in to Hermes with username `david` (`pass show hermes/dashboard/BASIC_AUTH_PASSWORD`).

**3.3 Sign in once in a browser.**

- Open `https://hermes.dvogeldev.com` on the laptop on coffee-shop wifi.
- CF Access bounces to `/cdn-cgi/access/login`. Enter your email; check inbox for the PIN; paste it in.
- Hermes login: username `david`, password from `pass show hermes/dashboard/BASIC_AUTH_PASSWORD`.
- You land on the Hermes dashboard with `default` profile selected. Sessions, Skills, MCP, Config, Status, and Chat — all reachable. Chat must stay connected (no `origin_mismatch` / WS 1006).

**3.4 Verify mobile** (resolves [#34](https://github.com/dvogeldev/remote-dev/issues/34)).

- Chrome DevTools device emulation at 390×844 (iPhone-ish).
- Check the surfaces an operator actually uses: profile switcher (only `default` exists; just confirm it renders), Sessions list, Chat tab, Cron Jobs form, Skills page, Config form.
- Expectation per [#34](https://github.com/dvogeldev/remote-dev/issues/34): **responsive web only**, no PWA. If most pages are usable on touch, lock that and close #34.

## Operating

### Add a second identity

- Zero Trust → **Access controls** → **Applications** → `hermes-dvogeldev` → **Policies** → `david-ops` → edit → add the email under **Include** → save. Takes effect on next login.

### Why gmail instead of david@dvogeldev.com

The original plan in [#31](https://github.com/dvogeldev/remote-dev/issues/31) was to allowlist `david@dvogeldev.com`. As of first deploy (2026-09-01), email hosting for `dvogeldev.com` isn't delivering Cloudflare Access OTPs to that address — so the allowlist was switched to `dvogelca@gmail.com` (the operator's working alias) to unblock sign-in. Once `dvogeldev.com` email is deliverable (MX, SPF, allowlist `notify.cloudflare.com` + IPs `104.30.16.2-7` on the gateway), update `cloudflare/dvd/ALLOWLIST_EMAIL` to `david@dvogeldev.com` and re-run `HERMES_TUNNEL_UUID=<UUID> ./scripts/provision-hermes-access.sh` — the policy PUT keeps `name=david-ops` and updates `include.email`. Then re-add `dvogelca@gmail.com` as a second identity under the same policy.

### Rotate the tunnel token

- On grr: `cloudflared tunnel rotate credentials hermes-gui --cred-file ~/.cloudflared/<UUID>.json` (writes a fresh JSON, the old one stops working).
- No restart needed; `cloudflared` hot-reloads.

### After a Hermes upgrade

- `hermes update` restarts `hermes-dashboard.service`. The tunnel is unaffected. `~/.cloudflared/` doesn't move.

### Update cloudflared

- `cloudflared` self-updates by default; the unit runs with `--no-autoupdate` to keep that off the critical path. To upgrade manually: download a fresh binary to `~/.local/bin/cloudflared` and `systemctl --user restart cloudflared.service`.

### Restart loops / flaps

- `journalctl --user -u cloudflared.service -n 200` — `cloudflared` logs to journal; missing/bad config is the usual cause.
- `auth_required: true` flipping to `false` from off-LAN: the CF Access app isn't matching, or the policy was deleted. Re-check Zero Trust → Access controls → Applications.

### Backups

- `~/.cloudflared/config.yml` and the credentials JSON — back these up (they're in the `~/.cloudflared` tree). The tunnel itself, the Access app, and the policy live in Cloudflare and don't need local backup.
- Re-creating the tunnel is `cloudflared tunnel create hermes-gui` + the same config — both can be rebuilt from this runbook + `host-plane/cloudflared-config.yml.example`.

## Files in this repo

| Path | What |
|---|---|
| `host-plane/cloudflared.service` | systemd --user unit for cloudflared. `After=hermes-dashboard.service` so the dashboard is up before the tunnel tries to reach it. |
| `host-plane/cloudflared-config.yml.example` | Tunnel config template. Replace `<TUNNEL-UUID>`, copy to `~/.cloudflared/config.yml`. |
| `scripts/install-cloudflared.sh` | AFK install on grr. Use `--start` after the config is in place. |

## Out of scope

- Running `hermes dashboard` itself — [#30](https://github.com/dvogeldev/remote-dev/issues/30).
- Hermes's own loopback auth — stays open loopback by design; CF Access is the only identity layer.
- A second identity — day one is single-operator per [#31](https://github.com/dvogeldev/remote-dev/issues/31).
- An in-box reverse proxy (nginx/caddy) — none, per [#30](https://github.com/dvogeldev/remote-dev/issues/30).
- PWA / mobile app — out of scope per [#27](https://github.com/dvogeldev/remote-dev/issues/27); responsive web is day one.

## Done means

- `https://hermes.dvogeldev.com/api/status` returns `auth_required: true` (the official Hermes recipe gate).
- An unauthenticated curl from off-LAN returns a 302 to the CF Access OTP page.
- An authenticated session reaches the Hermes dashboard with `default` profile selected.
- No public port is open on `grr` for 9119 (only 22/SSH and the tunnel).
- This runbook is committed and linked from [#35](https://github.com/dvogeldev/remote-dev/issues/35).