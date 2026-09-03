#!/usr/bin/env bash
# Checkout pass secrets onto grr-remote-dev-01 as ~/.hermes/.env (mode 600).
# Source of truth stays on the laptop (ADR-0007). Does not print secret values.
#
# Managed vars (each row is keyed by an explicit env var, populated from pass):
#   KILOCODE_API_KEY                       ←  kilocode/KILOCODE_API_KEY
#   OPENBRAIN_MCP_KEY                      ←  api/ingest-thought
#   BUZZ_PRIVATE_KEY                       ←  nostr/hermes-buzz/private-key   (ADR #0010)
#   HERMES_DASHBOARD_BASIC_AUTH_USERNAME   ←  hermes/dashboard/BASIC_AUTH_USERNAME
#   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD   ←  hermes/dashboard/BASIC_AUTH_PASSWORD
#   HERMES_DASHBOARD_BASIC_AUTH_SECRET     ←  hermes/dashboard/BASIC_AUTH_SECRET
#
# The .env is rewritten idempotently: existing unmanaged lines in ~/.hermes/.env
# are preserved; managed keys are set from pass (in canonical order), and any
# managed key whose pass entry is missing is dropped (so removing an entry from
# the pass tree also removes it from the VPS surface on next run).
set -euo pipefail

HOST="${HERMES_SSH_HOST:-grr}"

PASS_KILO="${PASS_KILO:-kilocode/KILOCODE_API_KEY}"
# Same edge-function access key authenticates ingest-thought *and* open-brain-mcp
# (query ?key= or header x-brain-key). Not a second brain; MCP read uses this.
PASS_OPENBRAIN="${PASS_OPENBRAIN:-api/ingest-thought}"
# Hermes v0 single Nostr key, generated and stored on the laptop per ADR #0010.
PASS_BUZZ="${PASS_BUZZ:-nostr/hermes-buzz/private-key}"
PASS_DASH_USER="${PASS_DASH_USER:-hermes/dashboard/BASIC_AUTH_USERNAME}"
PASS_DASH_PW="${PASS_DASH_PW:-hermes/dashboard/BASIC_AUTH_PASSWORD}"
PASS_DASH_SECRET="${PASS_DASH_SECRET:-hermes/dashboard/BASIC_AUTH_SECRET}"

if ! command -v pass >/dev/null; then
  echo "pass is not installed on this machine" >&2
  exit 1
fi

# Read a pass entry's first line, or empty string if the entry doesn't exist.
# Uses `pass show` so a missing entry degrades to "" rather than aborting the
# script — leaving us able to rewrite the env without unsetting other keys.
pass_first_line() {
  local entry="$1"
  if pass show "$entry" >/dev/null 2>&1; then
    pass show "$entry" | head -n1
  else
    echo ""
  fi
}

kilo="$(pass_first_line "$PASS_KILO")"
openbrain="$(pass_first_line "$PASS_OPENBRAIN")"
buzzpriv="$(pass_first_line "$PASS_BUZZ")"
dash_user="$(pass_first_line "$PASS_DASH_USER")"
dash_pw="$(pass_first_line "$PASS_DASH_PW")"
dash_secret="$(pass_first_line "$PASS_DASH_SECRET")"

# Canonical managed keys — order is observable in the resulting .env.
managed_order=(
  KILOCODE_API_KEY
  OPENBRAIN_MCP_KEY
  BUZZ_PRIVATE_KEY
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  HERMES_DASHBOARD_BASIC_AUTH_SECRET
)
declare -A managed_pass_entry=(
  [KILOCODE_API_KEY]="$kilo"
  [OPENBRAIN_MCP_KEY]="$openbrain"
  [BUZZ_PRIVATE_KEY]="$buzzpriv"
  [HERMES_DASHBOARD_BASIC_AUTH_USERNAME]="$dash_user"
  [HERMES_DASHBOARD_BASIC_AUTH_PASSWORD]="$dash_pw"
  [HERMES_DASHBOARD_BASIC_AUTH_SECRET]="$dash_secret"
)

# Merge-replace the existing .env on the VPS: read it, drop any of OUR
# managed keys (since pass is the truth for those), append ours in canonical
# order, write back. Unmanaged lines are preserved verbatim.
#
# The remote script uses a single-quoted heredoc delimiter so nothing local
# expands; the managed-key list is hardcoded in the remote body (it must stay
# in lockstep with the `case` arms below and with `managed_order` above).
ssh -o IdentitiesOnly=yes "$HOST" bash -s -- \
    "${managed_pass_entry[KILOCODE_API_KEY]}" \
    "${managed_pass_entry[OPENBRAIN_MCP_KEY]}" \
    "${managed_pass_entry[BUZZ_PRIVATE_KEY]}" \
    "${managed_pass_entry[HERMES_DASHBOARD_BASIC_AUTH_USERNAME]}" \
    "${managed_pass_entry[HERMES_DASHBOARD_BASIC_AUTH_PASSWORD]}" \
    "${managed_pass_entry[HERMES_DASHBOARD_BASIC_AUTH_SECRET]}" <<'REMOTE'
set -euo pipefail
new_kilo="$1"; new_openbrain="$2"; new_buzz="$3"
new_dash_user="$4"; new_dash_pw="$5"; new_dash_secret="$6"
umask 077
mkdir -p ~/.hermes
touch ~/.hermes/.env
tmp="$(mktemp ~/.hermes/.env.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

# Carry over unmanaged lines (anything not in our managed set), preserving order.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    KILOCODE_API_KEY=*|OPENBRAIN_MCP_KEY=*|BUZZ_PRIVATE_KEY=*|HERMES_DASHBOARD_BASIC_AUTH_USERNAME=*|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=*|HERMES_DASHBOARD_BASIC_AUTH_SECRET=*) ;;
    *) printf '%s\n' "$line" ;;
  esac
done < ~/.hermes/.env > "$tmp"

# Append our managed keys in canonical order, only those with non-empty values.
for key in KILOCODE_API_KEY OPENBRAIN_MCP_KEY BUZZ_PRIVATE_KEY \
           HERMES_DASHBOARD_BASIC_AUTH_USERNAME HERMES_DASHBOARD_BASIC_AUTH_PASSWORD HERMES_DASHBOARD_BASIC_AUTH_SECRET; do
  case "$key" in
    KILOCODE_API_KEY)  val="$new_kilo" ;;
    OPENBRAIN_MCP_KEY) val="$new_openbrain" ;;
    BUZZ_PRIVATE_KEY)  val="$new_buzz" ;;
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME) val="$new_dash_user" ;;
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD) val="$new_dash_pw" ;;
    HERMES_DASHBOARD_BASIC_AUTH_SECRET) val="$new_dash_secret" ;;
  esac
  if [ -n "$val" ]; then
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
done

mv "$tmp" ~/.hermes/.env
chmod 600 ~/.hermes/.env
echo "wrote ~/.hermes/.env ($(wc -c < ~/.hermes/.env) bytes)"
REMOTE

echo "Checkout complete."
echo "On the VPS, set the model to one of the configured providers, e.g.:"
echo "  hermes config set model.provider kilocode"
echo "  hermes config set model.default minimax/minimax-m3"
