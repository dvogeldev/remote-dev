# Buzz device-pairing sidecar on the host plane

Desktop Settings → Mobile pairing needs a dedicated NIP-AB WebSocket (`buzz-pair-relay`). The main Buzz relay advertises NIP-43 but does not serve `/pair`; without a sidecar, the desktop QR flow fails with `WebSocket connection failed: HTTP error: 404 Not Found`.

## Decision

Run `buzz-pair-relay` as a Compose sidecar (`pair`) from the same `BUZZ_IMAGE`, bound to `127.0.0.1:5000`. Route `buzz.dvogeldev.com/pair*` through the existing `buzz-relay` Cloudflare Tunnel to that loopback port. Advertise `BUZZ_PAIRING_RELAY_URL=wss://buzz.dvogeldev.com/pair` in the main relay's NIP-11 so clients skip the dead legacy fallback.

Did not pick a second public hostname (`pair.buzz.dvogeldev.com`): extra DNS and Access/WAF surface for a path the desktop already targets as `/pair` on the main host. Did not pick putting pairing on the main relay process: that binary has no `/pair` route.

## Consequences

- Compose grows a sixth service; `install-buzz.sh` waits for TCP `:5000` after relay health.
- Tunnel ingress is ordered: `/pair.*` first, then the relay catch-all with `httpHostHeader: 127.0.0.1:3000`. The pairing sidecar is not community-scoped; do not Host-rewrite it.
- `install-buzz.sh` Stage 4b upserts `BUZZ_PAIRING_RELAY_URL` when `BUZZ_PUBLIC_HOSTNAME` is set. `BUZZ_DOMAIN` and `RELAY_URL` stay loopback (ADR #0013).
- Plain HTTP GET `/pair` is expected to be **400** (WS-only). **404** means the path still hits the main relay.
