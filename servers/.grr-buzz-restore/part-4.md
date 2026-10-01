- Production observability (Prometheus + alerting). Metrics are exposed on
  `127.0.0.1:9102`; wiring them into anything is a follow-up.
- Anti-spam / rate-limit policy. The relay ships only `AlwaysAllowRateLimiter`
  per research; v0 mitigates by loopback-only bind. With the public hostname
  (see #53), CF-edge rate limits replace the loopback mitigation.
- Mobile clients, approval-gate workflow plumbing, attachments. Out of v0 per
  the map's Destination clause.
- An installed Postgres backup cron. v0 uses a calendar reminder + the
  manual procedure in "Backups" above. Revisit per ADR #0012 Q9.
- Off-host backup of the laptop `pass` tree itself. ADR-0007 establishes
  pass as the secret source; backing up pass (which holds everything
  else) is its own follow-up, separate from #52.

## Done means

- `scripts/install-buzz.sh` runs cleanly on a fresh `grr` with `pass buzz/relay/private-key` and `pass buzz/postgres-dumps/<latest>.sql` already in place (recovery story per ADR #0012 + #51).
- `docker compose ps` on grr shows `relay`, `postgres`, `redis`, `minio`, `minio-init` all `running` (or `exited (0)` for `minio-init`).
- `curl -fsS http://127.0.0.1:8080/_liveness` on grr returns the liveness line.
- `scripts/smoke-buzz.sh` shows "AUTH challenge received" or a relay response in any of its three checks.
- After `docker compose down -v` + re-running `install-buzz.sh`, the previously-stored channel + messages + members reappear (verified commit `<follow-up>`).
- An operator-created room in the Buzz desktop client results in Hermes responding to an `@hermes` mention within a few seconds (round-trip text demo, the [#36](https://github.com/dvogeldev/remote-dev/issues/36) destination gate).
- This runbook is committed and linked from [#47](https://github.com/dvogeldev/remote-dev/issues/47).
