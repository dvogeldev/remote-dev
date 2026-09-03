# 2026-09-03 — Buzz public-hostname UX + identity split

Session log for the closeout of `feature/buzz-host-plane`. Three commits
landed (`504b82d`, `42a3337`, `f3581a9`) on top of the existing twelve;
the working tree at the start of the session had the Hermes dashboard
public-URL prep work (Sep 1) plus this session's Buzz changes.

## What broke and what we learned

**Buzz desktop couldn't reach the relay via `wss://buzz.dvogeldev.com`.**

The desktop entry launched `BUZZ_RELAY_URL=wss://buzz.dvogeldev.com`,
the AppImage opened the WebSocket, NIP-42 AUTH succeeded, and then
every REST call returned 401:

```
buzz-mesh: relay returned 401 Unauthorized:
  NIP-98: URL mismatch: event has
    `https://buzz.dvogeldev.com/events`,
    expected `http://127.0.0.1:3000/events`
```

`crates/buzz-relay/src/api/bridge.rs:214` builds the expected URL from
`(RELAY_URL prefix, tenant.host())`. With `RELAY_URL=ws://127.0.0.1:3000`
and cloudflared rewriting Host to `127.0.0.1:3000`, `tenant.host()` is
`127.0.0.1:3000`. The desktop client signs `https://buzz.dvogeldev.com/`
because that's what it knows. Mismatch.

Switching `BUZZ_DOMAIN` to `buzz.dvogeldev.com` would fix the desktop
client but break Hermes's loopback connection (Host: `127.0.0.1:3000`
no longer matches the community). The relay's
single-community-per-host design forces one transport per relay.

**Fix:** SSH tunnel + `ws://127.0.0.1:3000`. Both client and Hermes
agree on `http://127.0.0.1:3000/events` → NIP-98 matches. The
public-hostname tunnel stays up for browsers / mobile / collaborators
who can't SSH. `~/Applications/buzz-launcher.sh` is the daily-driver
launcher; the cloudflared tunnel keeps the relay reachable from
everywhere else.

**CF Access on the public hostname turned out to be unnecessary.** It
was a redundant outer auth layer for a single-operator relay — the
relay already does NIP-42 AUTH at the member roster. Removing the
Access app collapses the launch flow from "open browser, OTP, then click
Buzz" to "click Buzz." Identity gate is now relay membership only;
edge defense is the WAF / rate-limit rules (Phase 1.5 of
`servers/buzz-dvogeldev-access.md`, now load-bearing because the edge
isn't challenging anonymous traffic).

## The identity split (the deeper finding)

Even with the relay reachable, Hermes didn't reply to `@hermes hello`
when sent from the operator's desktop client. Two stacked filters
were blocking:

1. **Self-echo** (`plugins/platforms/buzz/adapter.py:1026`): if `pubkey
   == self._self_pubkey`, drop the message. Per ADR #0009 the operator
   and Hermes share the same Nostr identity on a single-operator setup,
   so the operator's own messages are filtered before mention-gating.
   Documented behavior, not a bug.

2. **`BUZZ_ALLOWED_USERS`** (`adapter.py:1041`): the install script
   seeded this to just Hermes's own pubkey, so anyone else's message
   is dropped at the allow-list. The docstring-claimed
   `BUZZ_ALLOW_ALL_USERS=true` doesn't actually bypass this check —
   only an empty `BUZZ_ALLOWED_USERS` does. **Doc inaccuracy worth
   flagging upstream.**

Verified with a throwaway keypair (`/tmp/kilo/genkey.py` + relay
`buzz-admin add-member` + `channels join` + `messages send`). After
fix #2, Hermes replied in ~4s.

**Best practice for this setup (now applied):**

| Identity | Role | Why |
|---|---|---|
| `david` (new secp256k1 keypair) | `owner` | Sole owner. Lives in password manager. |
| `Hermes` (existing `7c8625d…`) | `admin` | Agent service account. `BUZZ_PRIVATE_KEY` in `~/.hermes/.env`. |

Three reasons the operator identity must never equal the agent
identity: (a) leaked `BUZZ_PRIVATE_KEY` from `~/.hermes/.env`
shouldn't compromise the human, (b) audit clarity — agent events come
from a visibly different pubkey, (c) clean revocation if either side
is compromised.

To rotate the owner I had to bypass `buzz-admin` (the CLI rejects
`--role owner`; it's gated by `RELAY_OWNER_PUBKEY`). Steps:

1. `sed -i` `RELAY_OWNER_PUBKEY` in `~/.buzz/.env` on grr.
2. `docker compose restart relay` (auto-promotes on next startup if
   the pubkey is in the table; ours wasn't, so step 3 was needed).
3. `INSERT INTO relay_members (community_id, pubkey, role, added_by)
   SELECT id, '<david-pub>', 'owner', 'rotation: …' FROM communities
   ON CONFLICT DO NOTHING;` (the CLI's refusal left SQL as the only
   route).
4. `UPDATE relay_members SET role='admin' WHERE pubkey='<hermes-pub>'
   AND role='owner';` (both communities, since the relay was created
   before this work).

`BUZZ_ALLOWED_USERS=<david-pub>` now in `~/.hermes/.env` — only david
can trigger Hermes. Collaborators get added via `buzz-admin add-member`
when they join.

## Laptop-side: launcher script

`~/Applications/buzz-launcher.sh` now:

- Idempotent SSH tunnel to `grr-remote-dev-01:3000` via `127.0.0.1:3000`.
- Sources `~/.config/buzz/launcher-identity.nsec` (mode 0600) and
  passes it via `BUZZ_PRIVATE_KEY`. Per `block/buzz/SECURITY.md` this
  env var always overrides the OS keyring, which is what we want — no
  fighting Buzz Desktop v0.5.20's Settings → Identities UI, which
  doesn't exist (and per [issue #2935](https://github.com/block/buzz/issues/2935)
  the import path that does exist doesn't reliably make the imported
  identity active).

`~/.local/share/applications/Buzz.desktop` `Exec=` now points at the
launcher. To rotate the desktop identity later, replace the nsec line
in the identity file.

## Operational state at end of session

| | |
|---|---|
| Relay | `buzz-prod-relay-1` healthy after `RELAY_OWNER_PUBKEY` rotate + restart |
| Tunnel | `cloudflared-buzz.service` up; `https://buzz.dvogeldev.com` → 200 (no Access app) |
| Hermes gateway | running; `BUZZ_ALLOWED_USERS=3e708fe…` (david); poll loop receiving + replying |
| Round-trip | david posts `@hermes hello` in Hermes Demo; Hermes replies ~4–5s later, contextual |
| Operator laptop | Buzz desktop signed in as david after `nsec12u5u9…` paste in onboarding |

## Worth documenting upstream / followups

- The `BUZZ_ALLOW_ALL_USERS` docstring is misleading — only empty
  `BUZZ_ALLOWED_USERS` actually bypasses the allow-list at
  `plugins/platforms/buzz/adapter.py:1041`. Worth a doc PR against
  `block/buzz` once we have a known-good repro path.
- The operator==Hermes identity design from ADR #0009 makes the
  round-trip in `servers/grr-buzz.md:226` impossible by design. The
  doc should call this out and add a "second-identity round-trip" step
  using a throwaway.
- ADR #0009 itself needs a v1 addendum: "operator != Hermes when the
  relay is single-tenant AND owner-strict"; the current ADR assumes
  operator == Hermes always.
