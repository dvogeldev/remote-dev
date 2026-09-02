#!/usr/bin/env bash
# Enable and configure the bundled Hermes buzz plugin (#48).
#
# AFK on the laptop. Drives grr-remote-dev-01 over SSH. Runs the same
# hermes CLI the dashboard install uses, but for the messaging gateway
# (separate systemd --user service from hermes-dashboard.service).
#
# What this does:
#   - Generates a placeholder UUID for BUZZ_HOME_CHANNEL / BUZZ_CHANNELS.
#     The operator MUST overwrite this after creating the real demo
#     room in the Buzz desktop client (see servers/grr-buzz.md Phase 2).
#   - Writes BUZZ_RELAY_URL, BUZZ_TRANSPORT, BUZZ_HOME_CHANNEL,
#     BUZZ_CHANNELS, BUZZ_ALLOWED_USERS into ~/.hermes/.env on grr.
#     Hermes's keypair (BUZZ_PRIVATE_KEY) is already there per #46.
#   - Sets gateway.platforms.buzz.enabled: true in ~/.hermes/config.yaml.
#   - Runs `hermes gateway install` to create the user-level systemd
#     service hermes-gateway.service, then `hermes gateway start`.
#   - Verifies via `hermes gateway status` that the buzz plugin
#     initialised without errors.
#
# What this does NOT do:
#   - Install the `buzz` CLI binary. The plugin shells out to it for
#     outbound sends (--transport=poll fallback). For WebSocket inbound
#     (the default in v0), the CLI is only needed on send. Operators who
#     want to drive Hermes from Buzz can `cargo install buzz-cli` from
#     the block/buzz repo; for v0 demo it's optional and #49's
#     round-trip may surface the gap.
#   - Register Hermes as a workspace member. That's a buzz-admin step on
#     the relay container, owned by servers/grr-buzz.md Phase 2.
#   - Create the demo room. HITL via the Buzz desktop client.
set -euo pipefail

HOST="${HOST:-grr}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
SHIM_SRC="${ROOT}/host-plane/buzz-shim/buzz"
REMOTE_SHIM=/tmp/buzz-shim

if [[ ! -f "$SHIM_SRC" ]]; then
  echo "missing: $SHIM_SRC" >&2
  exit 1
fi

copy_local_to_remote() {
  scp -q "$1" "$HOST:$2"
}

remote_bash() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" bash -s -- "$@"
}

echo "target=$HOST shim=$SHIM_SRC"
copy_local_to_remote "$SHIM_SRC" "$REMOTE_SHIM"

remote_bash <<'EOS'
set -euo pipefail
HERMES="$HOME/.local/bin/hermes"
ENV="$HOME/.hermes/.env"
CFG="$HOME/.hermes/config.yaml"

# Install the buzz CLI shim. The plugin's connect() hard-fails if
# BUZZ_CLI_PATH (or `buzz` on PATH) is missing, so a stub that handles
# the three subcommands it needs (users, channels, messages) is required
# even for inbound-only WebSocket transport. See host-plane/buzz-shim/buzz
# for the contract.
#
# We install to ~/.local/bin/buzz (writable by the user) and set
# BUZZ_CLI_PATH explicitly in ~/.hermes/.env below — `~/.local/bin` is
# not on the default PATH for systemd --user services, so PATH lookup
# alone won't find it.
shim_src="/tmp/buzz-shim"
shim_dst="$HOME/.local/bin/buzz"
mkdir -p "$(dirname "$shim_dst")"
install -m 0755 "$shim_src" "$shim_dst"
# Verify it runs and reports version.
echo "  installed shim: $("$shim_dst" version)"

# ---------------------------------------------------------------------------
# 0. Sanity
# ---------------------------------------------------------------------------
[[ -x "$HERMES" ]] || { echo "FATAL: $HERMES missing — run scripts/install-hermes-dashboard.sh / hermes install first." >&2; exit 1; }
[[ -s "$ENV" ]]    || { echo "FATAL: $ENV missing — run scripts/unwrap-hermes-env.sh first." >&2; exit 1; }
grep -q '^BUZZ_PRIVATE_KEY=' "$ENV" || { echo "FATAL: BUZZ_PRIVATE_KEY missing from $ENV — run scripts/unwrap-hermes-env.sh first." >&2; exit 1; }

# Hermes's pubkey (for placeholder BUZZ_ALLOWED_USERS). The operator
# overwrites this with their own Nostr pubkey per servers/grr-buzz.md.
hermes_nsec="$(grep '^BUZZ_PRIVATE_KEY=' "$ENV" | head -n1 | cut -d= -f2-)"
[[ -n "$hermes_nsec" ]] || { echo "FATAL: empty BUZZ_PRIVATE_KEY" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Generate a placeholder UUID. Operators replace this with the real
#    demo-room UUID after creating the room in the Buzz desktop client.
# ---------------------------------------------------------------------------
placeholder_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
echo "  placeholder room UUID: $placeholder_uuid"

# ---------------------------------------------------------------------------
# 2. Merge-replace BUZZ_* keys in ~/.hermes/.env (preserves unmanaged lines,
#    analogous to scripts/unwrap-hermes-env.sh).
# ---------------------------------------------------------------------------
umask 077
tmp="$(mktemp "$ENV.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Drop existing BUZZ_* keys; we'll re-add ours in canonical order.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    BUZZ_RELAY_URL=*|BUZZ_TRANSPORT=*|BUZZ_HOME_CHANNEL=*|BUZZ_CHANNELS=*|BUZZ_ALLOWED_USERS=*|BUZZ_AUTH_TAG=*|BUZZ_POLL_INTERVAL=*|BUZZ_CLI_PATH=*|BUZZ_CREDENTIALS_FILE=*|BUZZ_ALLOW_ALL_USERS=*) ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$ENV" > "$tmp"
cat >> "$tmp" <<EOC
# --- Hermes buzz plugin (#48) ----------------------------------------------------
# Loopback-only v0. BUZZ_HOME_CHANNEL + BUZZ_CHANNELS are placeholder UUIDs
# the operator MUST replace after creating the real demo room in the Buzz
# desktop client (servers/grr-buzz.md Phase 2). BUZZ_CLI_PATH points at the
# Python shim installed by this script; see host-plane/buzz-shim for details
# and how to swap for the real CLI binary built from block/buzz.
BUZZ_RELAY_URL=ws://127.0.0.1:3000
BUZZ_TRANSPORT=websocket
BUZZ_HOME_CHANNEL=$placeholder_uuid
BUZZ_CHANNELS=[$placeholder_uuid]
BUZZ_ALLOWED_USERS=[__HERMES_PUBHEX_PLACEHOLDER__]
BUZZ_CLI_PATH=$HOME/.local/bin/buzz
EOC
mv "$tmp" "$ENV"
chmod 0600 "$ENV"

# Re-read and substitute the actual Hermes pubhex into BUZZ_ALLOWED_USERS.
# We use python so we can call `nak key public` semantics without relying
# on nak being installed on grr — the npub from the mirrored file is
# already there from the chezmoi mirror.
hermes_pubhex="$(python3 - <<PY
# Decode an nsec bech32 string into the raw 32-byte secret (xonly scalar).
# We don't need BIP-340 derivation here — we just want the hex of the
# secret bytes. (Hermes's BUZZ_PRIVATE_KEY is the secret scalar; for
# BUZZ_ALLOWED_USERS we want Hermes's xonly pubkey. We rely on the
# ~/.hermes/nostr.npub mirror from the chezmoi pass→env checkout, or
# fall back to deriving via nak if installed.)
import os
npub_file = os.path.expanduser("~/.hermes/nostr.npub")
if os.path.exists(npub_file):
    with open(npub_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith("npub1"):
                # bech32 → 5-bit groups → bytes → hex (xonly pubkey)
                CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
                s = line[5:]  # strip bech32 hrp + separator
                # bech32 decode (no checksum check — file is local-trusted)
                data = [CHARSET.index(c) for c in s if c in CHARSET]
                # convert 5-bit groups to 8-bit bytes
                acc, bits = 0, 0
                out = bytearray()
                for v in data[:-6]:  # drop 6-char checksum
                    acc = (acc << 5) | v
                    bits += 5
                    if bits >= 8:
                        bits -= 8
                        out.append((acc >> bits) & 0xFF)
                print(out.hex())
                break
PY
)"
if [[ -z "$hermes_pubhex" ]]; then
  echo "FATAL: could not derive Hermes pubhex from ~/.hermes/nostr.npub" >&2
  exit 1
fi
echo "  Hermes pubhex: $hermes_pubhex"
# Replace the placeholder in BUZZ_ALLOWED_USERS with the real hex.
sed -i "s|BUZZ_ALLOWED_USERS=\\[__HERMES_PUBHEX_PLACEHOLDER__\\]|BUZZ_ALLOWED_USERS=[$hermes_pubhex]|" "$ENV"
chmod 0600 "$ENV"
grep -E '^BUZZ_' "$ENV" | sed 's/=.*/=<set>/'

# ---------------------------------------------------------------------------
# 3. Ensure gateway.platforms.buzz.enabled: true in ~/.hermes/config.yaml.
#    Idempotent: replaces the line if present, otherwise inserts a fresh
#    `gateway:` block before any existing top-level mapping. We don't try
#    to merge into a partial `gateway:` block because Hermes's own config
#    loader is canonical and would overwrite on next save anyway.
# ---------------------------------------------------------------------------
if [[ ! -s "$CFG" ]]; then
  cat > "$CFG" <<'YAML'
gateway:
  platforms:
    buzz:
      enabled: true
YAML
else
  if grep -qE '^[[:space:]]*buzz:[[:space:]]*$' "$CFG"; then
    # buzz: stanza exists; set enabled under it (best-effort — Hermes
    # canonicalises on next save).
    if grep -qE '^[[:space:]]*buzz:[[:space:]]*$' "$CFG" \
       && grep -qA3 '^[[:space:]]*buzz:' "$CFG" | grep -qE 'enabled:'; then
      # already has an `enabled:` line — leave as-is (operator manages).
      :
    else
      # insert enabled: true under buzz:
      awk '
        /^[[:space:]]*buzz:[[:space:]]*$/ { print; print "      enabled: true"; next }
        { print }
      ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    fi
  else
    # No buzz stanza yet — append a fresh gateway.platforms.buzz block.
    cat >> "$CFG" <<'YAML'

# Hermes buzz plugin (#48) — loopback-only v0.
gateway:
  platforms:
    buzz:
      enabled: true
YAML
  fi
fi
chmod 0600 "$CFG"
echo "  config.yaml gateway section:"
grep -A4 '^gateway:' "$CFG" | head -8

# ---------------------------------------------------------------------------
# 4. Install + start the gateway systemd user service.
#    `hermes gateway install` creates ~/.config/systemd/user/hermes-gateway.service.
#    `--start-now` starts it immediately; `--start-on-login` enables linger
#    semantics via systemd (handled by install-hermes-dashboard.sh earlier).
# ---------------------------------------------------------------------------
echo "  installing hermes-gateway.service..."
"$HERMES" gateway install --start-now 2>&1 | tail -5

# Give it a moment to start, then verify.
sleep 3
echo "  gateway status:"
"$HERMES" gateway status 2>&1 | head -25

echo ""
echo "================================================================="
echo "  Hermes buzz plugin enabled. Placeholder values left as-is —"
echo "  the operator MUST replace per servers/grr-buzz.md Phase 2:"
echo "    BUZZ_HOME_CHANNEL=$placeholder_uuid  (replace after creating the demo room)"
echo "    BUZZ_CHANNELS=[$placeholder_uuid]    (same)"
echo "    BUZZ_ALLOWED_USERS=[$hermes_pubhex]   (replace with operator's Nostr pubkey)"
echo ""
echo "  The buzz CLI binary is NOT installed on grr. Outbound sends"
echo "  (Hermes -> Buzz) need it; inbound (Buzz -> Hermes) uses the"
echo "  WebSocket transport (BUZZ_TRANSPORT=websocket) and does NOT."
echo "  For v0 demo, inbound is the wire we exercise (#49). Build the"
echo "  real buzz CLI from block/buzz (cargo install --git https://github.com/block/buzz"
echo "  --bin buzz-cli --locked) on grr when outbound is needed; the shim then"
echo "  becomes obsolete (rm ~/.local/bin/buzz)."
echo "================================================================="
EOS