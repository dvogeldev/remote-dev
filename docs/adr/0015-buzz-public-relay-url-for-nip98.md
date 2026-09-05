# Public `RELAY_URL` for NIP-98 (desktop + mobile)

Desktop and mobile on `wss://buzz.dvogeldev.com` sign NIP-98 as `https://buzz.dvogeldev.com/query`. With `RELAY_URL=ws://127.0.0.1:3000` and cloudflared Host-rewrite to `127.0.0.1:3000`, the relay expected `http://127.0.0.1:3000/query` and returned 401. ADR #0013 kept loopback `RELAY_URL` so Hermes’s loopback client matched; that made public clients unusable for search, pairing import, and `/query`.

## Decision

The community identity is the **public hostname**. `RELAY_URL=wss://buzz.dvogeldev.com`, `BUZZ_DOMAIN=buzz.dvogeldev.com`, communities.host = `buzz.dvogeldev.com`. The tunnel does **not** rewrite Host. Hermes uses `BUZZ_RELAY_URL=wss://buzz.dvogeldev.com` (hairpin through the tunnel, verified 200 from `grr`).

Did not keep Host-rewrite + loopback `RELAY_URL`: public NIP-98 can never match. Did not run two live communities (`127.0.0.1:3000` vs `buzz.dvogeldev.com`): real history was on loopback; the public row was empty.

## Consequences

- `install-buzz.sh` Stage 4b may set `RELAY_URL` / `BUZZ_DOMAIN` when `BUZZ_PUBLIC_HOSTNAME` is set (supersedes ADR #0013’s “leave them loopback”).
- Loopback smoke (`Host: 127.0.0.1:3000`) no longer resolves the live community; use the public hostname or `Host: buzz.dvogeldev.com`.
- Hermes depends on the Cloudflare hairpin path, not `ws://127.0.0.1:3000`.
