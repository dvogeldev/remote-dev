# Hermes ops checklist (operator)

Day-two / recurring checks for the Hermes stack on `grr-remote-dev-01`. Does not reopen ADRs. Laptop-driven scripts; no secrets in this file.

## 1. Unwrap Hermes env (secrets checkout)

From the laptop, with `pass` unlocked:

```bash
cd /path/to/remote-dev
HOST=grr ./scripts/unwrap-hermes-env.sh
```

Confirms `~/.hermes/.env` and `~/.hermes/nostr.{npub,nsec}` match laptop `pass` (ADR-0007 / ADR-0010). Re-run after Hermes key rotation or a fresh VPS.

## 2. Smoke Buzz

```bash
HOST=grr ./scripts/smoke-buzz.sh
```

Expect liveness/readiness, NIP-42 AUTH challenge, and a relay response on the wire. Public-hostname check is opt-in when `BUZZ_PUBLIC_HOSTNAME` is set — see [`servers/grr-buzz.md`](../../servers/grr-buzz.md) and [`servers/buzz-dvogeldev-access.md`](../../servers/buzz-dvogeldev-access.md).

## 3. Dashboard access

| Path | How |
|------|-----|
| Loopback on grr | `curl -fsS http://127.0.0.1:9119/api/status` |
| Public | `https://hermes.dvogeldev.com` behind Cloudflare Access (OTP + email allowlist) |

Runbook: [`servers/hermes-dvogeldev-access.md`](../../servers/hermes-dvogeldev-access.md). Unit: `hermes-dashboard.service`. Auth-required must stay `true` when `HERMES_DASHBOARD_PUBLIC_URL` is set.

## 4. When to leave the local Hermes shell

Default is `terminal.backend: local` (ADR-0004). Prefer an isolated / Docker backend for untrusted scripts, unknown installers, or anything that must not see `~/.hermes` / `~/.buzz`.

Full criteria: [`untrusted-jobs.md`](untrusted-jobs.md).

## 5. Monthly KB refresh (Grok Bot side)

On the Grok / Cursor plane (not Nous Hermes on the VPS):

1. Follow `/workspace/hermes-knowledge-base/actionable-checklist.md` item **8b** (X + Reddit → dated `raw/*.json` → LIVE sections).
2. Bridge map: `/workspace/hermes-knowledge-base/ops-bridge.md`.
3. Optional Calendar reminder under actionable-checklist item **8**.

Do not invent star counts or social quotes. No VPS SSH required for the KB refresh itself.

## Quick index

| Need | Where |
|------|--------|
| Domain language | [`CONTEXT.md`](../../CONTEXT.md) |
| Current topology | [`references/system-diagram.md`](../../references/system-diagram.md) |
| Buzz install / rotate / backup | [`servers/grr-buzz.md`](../../servers/grr-buzz.md) |
| Host inventory | [`servers/grr-remote-dev-01.md`](../../servers/grr-remote-dev-01.md) |
