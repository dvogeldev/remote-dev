#!/usr/bin/env bash
# Checkout pass secrets onto grr-remote-dev-01 as ~/.hermes/.env (mode 600).
# Source of truth stays on the laptop (ADR-0007). Does not print secret values.
set -euo pipefail

HOST="${HERMES_SSH_HOST:-grr}"
PASS_KILO="${PASS_KILO:-kilocode/KILOCODE_API_KEY}"
# Same edge-function access key authenticates ingest-thought *and* open-brain-mcp
# (query ?key= or header x-brain-key). Not a second brain; MCP read uses this.
PASS_OPENBRAIN="${PASS_OPENBRAIN:-api/ingest-thought}"

if ! command -v pass >/dev/null; then
  echo "pass is not installed on this machine" >&2
  exit 1
fi

if ! pass show "$PASS_KILO" >/dev/null 2>&1; then
  echo "Missing pass entry: $PASS_KILO" >&2
  echo "Create it:  pass insert $PASS_KILO" >&2
  exit 1
fi

kilo="$(pass show "$PASS_KILO" | head -n1)"
if [[ -z "$kilo" ]]; then
  echo "Empty value in $PASS_KILO" >&2
  exit 1
fi

if ! pass show "$PASS_OPENBRAIN" >/dev/null 2>&1; then
  echo "Missing pass entry: $PASS_OPENBRAIN" >&2
  echo "Create it:  pass insert $PASS_OPENBRAIN" >&2
  exit 1
fi

openbrain="$(pass show "$PASS_OPENBRAIN" | head -n1)"
if [[ -z "$openbrain" ]]; then
  echo "Empty value in $PASS_OPENBRAIN" >&2
  exit 1
fi

{
  printf 'KILOCODE_API_KEY=%s\n' "$kilo"
  printf 'OPENBRAIN_MCP_KEY=%s\n' "$openbrain"
} | ssh -o IdentitiesOnly=yes "$HOST" 'umask 077; mkdir -p ~/.hermes && cat > ~/.hermes/.env && chmod 600 ~/.hermes/.env && echo "wrote ~/.hermes/.env ($(wc -c < ~/.hermes/.env) bytes)"'

echo "Checkout complete. On the VPS: hermes config set model.provider kilocode && hermes config set model.default minimax/minimax-m2.7"
