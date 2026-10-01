# Buzz image pin (ops)

Canonical runbook lives in [`servers/grr-buzz.md`](../../servers/grr-buzz.md) § **Ops note: pin Buzz image off `:main` before calling v0 done**.

Summary (no new ADR — Decisions locked already TODOs `:sha-<7>`):

1. After a good smoke on grr: `cd ~/.buzz && docker compose images` — record RepoDigest.
2. Pin `image:` in `~/.buzz/compose.yml` + keep `host-plane/buzz-compose.yml` in sync to `ghcr.io/block/buzz@sha256:…` or `:sha-<7>` (not `:main`).
3. Re-run `HOST=grr ./scripts/smoke-buzz.sh`.
4. Prefer upstream `relay-v*` GHCR tags when published.

Also linked from [`hermes-ops-checklist.md`](hermes-ops-checklist.md).
