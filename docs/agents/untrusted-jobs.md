# Untrusted jobs vs local Hermes shell

ADR-0004 keeps Hermes `terminal.backend: local` so sessions see `~/agency` and `~/projects` and can `devcontainer exec`. That is host-user power next to Buzz (Postgres/Redis/MinIO).

## Daily path (default)
- Trusted coding, canon edits, drain-inbox, smoke scripts David owns → **local** shell.

## Prefer Docker / isolated backend when
- Running untrusted third-party scripts or unknown installers
- Evaluating random GitHub CLIs without review
- Bulk web-download + execute pipelines
- Anything that should not see `~/.hermes/.env` or `~/.buzz`

## Do not
- Reintroduce shared `dev-base` as the daily desktop (rejected)
- Mount `~/.hermes` into a sandbox workspace
- Turn YOLO / disable approvals for untrusted work

## Related
- ADR-0004, ADR-0003, `CONTEXT.md`
- Ops checklist: [`hermes-ops-checklist.md`](hermes-ops-checklist.md)
- Current diagram: `references/system-diagram.md`
- Archived diagram: `references/historical/system-diagram-container-first.md`
