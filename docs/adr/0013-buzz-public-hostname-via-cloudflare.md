# Buzz public hostname via Cloudflare Tunnel + Access

Surfacing the host-plane Buzz relay at `buzz.dvogeldev.com` for multi-operator, multi-device, and mobile access: a dedicated `cloudflared` daemon on `grr-remote-dev-01` fronts the loopback relay over a Cloudflare Tunnel, and a Cloudflare Access self-hosted app gates the public hostname with the same OTP + email-allowlist identity layer used by `hermes.dvogeldev.com`. The relay itself stays loopback-bound; only the tunnel daemon exposes a single ingress endpoint. Two tunnels (one per public hostname), not one — the relay and the Hermes dashboard have different lifetimes and different Access policies, and tunnel rotation on one shouldn't restart the other.

## Consequences

### Two tunnels, not one

The existing `cloudflared.service` already runs the `hermes-gui` tunnel terminating at `127.0.0.1:9119`. Buzz gets its own tunnel (`buzz-relay`) terminating at `127.0.0.1:3000`, in its own systemd --user unit (`cloudflared-buzz.service`). Each tunnel has exactly one credentials JSON, one config, one CF Access app. Cost: two daemons on the host plane, two CF Tunnel objects to manage. Benefit: independent restart / rotation / outage boundaries, independent Access policies (a Hermes dashboard lockout doesn't lock out Buzz, and vice versa), and the upgrade cadence of the relay doesn't drag the dashboard tunnel with it. The shared assumption — that the host plane runs `cloudflared` for fronted egress — is established by `hermes.dvogeldev.com` and is now the standing pattern.

### The relay itself stays loopback-bound; only the tunnel changes

The relay's `BUZZ_HTTP_PORT` continues to bind `127.0.0.1:3000`. The tunnel unit's ingress is `http://127.0.0.1:3000` (loopback, no TLS). TLS terminates at the Cloudflare edge; the relay speaks plain HTTP/WS to `cloudflared`. This matches the v0 posture for `hermes.dvogeldev.com` exactly and means there is **no public port on `grr`** for Buzz — only 22/SSH and the tunnel. The `BUZZ_HEALTH_PORT=8080` and `BUZZ_METRICS_PORT=9102` continue to bind loopback and are unreachable from the public hostname (no path is routed for them); operator-side health checks stay on SSH or Tailscale.

### Auth is layered: CF Access at the edge, NIP-42 in the relay

The public hostname gets CF Access in front (email allowlist + OTP, mirroring `hermes.dvogeldev.com`). Inside, the relay still requires NIP-42 AUTH for every WS message and `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` for membership gating. These do **not** replace each other: CF Access gates the *TCP connection* (who can open a WebSocket at all); NIP-42 + membership gate the *events* (which Nostr pubkeys the relay accepts messages from). Both layers are necessary; removing either leaves a gap. The relay's `BUZZ_ALLOW_NIP_OA_AUTH=true` is unrelated — that's for NIP-OA (Open Authorization) flows within Nostr, not web auth.

### `BUZZ_DOMAIN` becomes the public hostname

v0 set `BUZZ_DOMAIN=127.0.0.1` so the relay's host→community resolver accepts WS connections with `Host: 127.0.0.1:3000`. Public-hostname mode sets `BUZZ_DOMAIN=buzz.dvogeldev.com` so the resolver accepts connections with `Host: buzz.dvogeldev.com` (which is what `cloudflared` sends after `Host`-rewriting... wait, it does NOT rewrite — see "Why no Host rewrite"). The new `BUZZ_PUBLIC_HOSTNAME` env knob in `~/.buzz/.env` selects which mode the relay runs in: unset → loopback (v0 behavior preserved); set → public hostname. `install-buzz.sh` detects the existing `.env`, leaves operator-tunable values alone, and rewrites the `BUZZ_DOMAIN*` block to match.

### Why no Host rewrite (and what that means)

Just like `hermes.dvogeldev.com`, `cloudflared` for Buzz does **not** rewrite the `Host` header to `127.0.0.1`. The relay's host→community resolver is configured (`BUZZ_DOMAIN=buzz.dvogeldev.com`) to accept the public hostname as its own. Rewriting would break the WS path: `cloudflared` proxies the WS Upgrade to the origin with the original `Host: buzz.dvogeldev.com`, the relay matches it against `BUZZ_DOMAIN`, and the WS proceeds. CORS (`BUZZ_CORS_ORIGINS`) and the media server (`BUZZ_MEDIA_SERVER_DOMAIN`) follow from this — they all use the public hostname. `BUZZ_MEDIA_BASE_URL=https://buzz.dvogeldev.com/media` so the desktop client constructs attachment URLs that resolve through the tunnel.

### Edge-path gating: only `/` and `/media/*` are public

The cloudflared ingress for `buzz.dvogeldev.com` routes `service: http://127.0.0.1:3000` for the catch-all. Admin/internal paths (`/metrics`, `/_readiness`) bind to **separate loopback ports** (9102, 8080) that the tunnel never touches — so they're unreachable from the public hostname by construction, not by a path-allowlist. This is stronger than a path-allowlist (a misconfigured `path:` regex can't accidentally expose them) and cheaper to maintain. The only paths that reach the relay through the tunnel are WS upgrades and `/media/*` GETs, both of which the relay's HTTP layer is already designed to serve.

### Rate limiting and abuse live at the CF edge

The relay ships only `AlwaysAllowRateLimiter` — every connected client gets unlimited event throughput. v0 mitigated this by loopback-only bind; the public hostname removes that mitigation. The CF edge carries the rate-limit policy instead, via a WAF custom rule (HTTP flood) or a Cloudflare Rate Limit rule (per-IP, per-path). Implementation lives in `servers/buzz-dvogeldev-access.md`; this ADR only locks that the policy lives at the edge, not in the relay. Revisit when Block ships a built-in rate limiter (research surface in #38).

### Tailscale path retired

With the public hostname in place, the `/etc/hosts` workaround for `127.0.0.1 grr-remote-dev-01` is no longer needed — the operator points the desktop client at `wss://buzz.dvogeldev.com` and the CF Access OTP login (which the client can handle via browser handoff) gates access. Mobile clients (Buzz mobile exists) work the same way. The SSH-tunnel path stays as a fallback for the operator on a degraded network where the tunnel is down — documented in `servers/grr-buzz.md` "Recover from a fresh VPS."

## Considered options (for the public-hostname shape)

- **(a) `cloudflared` + Cloudflare Tunnel + CF Access (one tunnel)** ← rejected because Hermes dashboard and Buzz have different lifetimes and Access policies; coupling them via one tunnel means a tunnel restart takes both down together.
- **(b) `cloudflared` + Cloudflare Tunnel + CF Access (two tunnels, dedicated to each hostname)** ← chosen. Locked above.
- **(c) Caddy-in-front on `grr`, public IP + Let's Encrypt** — rejected because it would require opening ports 80/443 on `grr`, exposes the VPS IP at the DNS layer, and adds a second TLS termination (origin + edge) for no benefit. `cloudflared` is egress-only; no inbound ports.
- **(d) Tailscale Funnel** — rejected because Funnel publishes the service to the public internet but goes through Tailscale's auth, not CF Access; no OTP / email allowlist story. Also a second identity layer (Tailscale account) for an operator who already gates on Cloudflare OTP. Per `CONTEXT.md` §Tailscale, Tailscale is the LAN extension, not the public-auth surface.
- **(e) VPS public IP + a hardened reverse proxy + fail2ban + manual cert renewal** — rejected for operational cost. CF Tunnel's cert renewal is automatic; rate limiting is one click in the dashboard. fail2ban + cert-manager on `grr` is more failure modes per surface area.

## Considered options (for the auth model)

- **(a) CF Access OTP + email allowlist, NIP-42 in the relay** ← chosen above. Two layers, each with a clear responsibility (TCP gate vs. event gate).
- **(b) NIP-42 only, no CF Access** — rejected because NIP-42 is per-pubkey and the desktop client doesn't (yet) speak it for the login handshake; CF Access handles the "open the client at all" step. NIP-42 is for message-level authz after the connection is open.
- **(c) Cloudflare Access + NIP-42 + a NIP-05 verified handle on the relay** — deferred; reserved for the day a second operator joins and we need a per-pubkey allowlist visible at the relay layer instead of operator-edited env vars.
- **(d) Mutual TLS at the edge** — rejected for the desktop client; the client doesn't ship a cert. Mobile is the same story.
