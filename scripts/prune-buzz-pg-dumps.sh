#!/usr/bin/env bash
# Prune old Buzz Postgres dumps from pass (#52, ADR #0012 Q9).
#
# AFK on the laptop. Reads `pass ls <dir>`, parses filenames matching
# `YYYYMMDDTHHMMSSZ.sql`, deletes entries older than
# BUZZ_PG_DUMPS_RETENTION_DAYS (default 90).
#
# Idempotent — re-running on a clean tree is a no-op. Logs every kept
# and pruned entry so the operator sees the result on every backup run.
#
# Override the pass directory with BUZZ_PG_DUMPS_DIR for testing
# (sandbox trees); the production value is `buzz/postgres-dumps`.
set -euo pipefail

RETENTION_DAYS="${BUZZ_PG_DUMPS_RETENTION_DAYS:-90}"
PASS_DIR="${BUZZ_PG_DUMPS_DIR:-buzz/postgres-dumps}"

if ! command -v pass >/dev/null; then
  echo "FATAL: pass not installed" >&2
  exit 1
fi

if ! pass ls "$PASS_DIR" >/dev/null 2>&1; then
  echo "  $PASS_DIR is not in pass (nothing to prune)"
  exit 0
fi

# Cutoff: now minus retention days, in epoch seconds (UTC).
cutoff_epoch="$(date -u -d "$RETENTION_DAYS days ago" +%s)"
cutoff_human="$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ)"
now_human="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  prune pass entries older than $cutoff_human  (retention=$RETENTION_DAYS days, now=$now_human)"

kept=()
pruned=()
unknown=()

while IFS= read -r line; do
  # pass ls output: (a) ANSI color escapes wrapping the filename, (b) box-
  # drawing tree characters (├── / └── / │ ), (c) the directory name on
  # its own line. Strip all three before matching.
  # 1. ANSI escapes (\x1b[<params>m).
  # 2. Leading tree chars + spaces (non-greedy: ── │ ├ └ ─ ).
  line="$(printf '%s' "$line" | sed -E $'s/\x1b\\[[0-9;]*m//g; s/^[│├└─ ]+//')"
  # 3. Trim whitespace.
  line="$(echo "$line" | xargs)"
  # Skip directory line ("buzz/postgres-dumps" with no tree chars after
  # step 2 leaves the dir name as the line content).
  [[ -z "$line" || "$line" == "$PASS_DIR" ]] && continue

  fname="$line"

  # Validate YYYYMMDDTHHMMSSZ.sql
  if [[ ! "$fname" =~ ^([0-9]{8}T[0-9]{6}Z)\.sql$ ]]; then
    unknown+=("$fname")
    continue
  fi
  ts="${BASH_REMATCH[1]}"

  # Parse the timestamp to epoch seconds. Format: 20260101T000000Z → 2026-01-01T00:00:00Z
  ts_human="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}"
  ts_epoch="$(date -u -d "$ts_human" +%s 2>/dev/null || echo "")"
  if [[ -z "$ts_epoch" || "$ts_epoch" -le 0 ]]; then
    unknown+=("$fname")
    continue
  fi

  if (( ts_epoch < cutoff_epoch )); then
    pruned+=("$fname")
  else
    kept+=("$fname")
  fi
done < <(pass ls "$PASS_DIR" | sed -E $'s/\x1b\\[[0-9;]*m//g')

# Report unknown / malformed filenames (operator should rename or remove
# them by hand; the prune loop can't touch what it doesn't understand).
if (( ${#unknown[@]} > 0 )); then
  echo "  WARN: ${#unknown[@]} malformed filename(s) skipped:"
  printf '    - %s\n' "${unknown[@]}"
fi

echo "  kept (${#kept[@]} entries within retention):"
if (( ${#kept[@]} > 0 )); then
  printf '    - %s\n' "${kept[@]}"
fi

echo "  prune (${#pruned[@]} entries older than $RETENTION_DAYS days):"
for f in "${pruned[@]}"; do
  if pass rm -f "$PASS_DIR/$f" >/dev/null; then
    printf '    - removed: %s\n' "$f"
  else
    printf '    - FAILED to remove: %s\n' "$f" >&2
  fi
done

echo ""
echo "Done. ${#kept[@]} kept, ${#pruned[@]} pruned (${#unknown[@]} skipped)."