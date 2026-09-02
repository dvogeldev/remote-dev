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
#   - Install the real `buzz` CLI binary. Without it, the plugin's
#     connect() hard-fails at startup. We install the official binary
#     shipped inside the desktop AppImage at usr/bin/buzz — see the
#     "Install the real buzz CLI" section below. The plugin's outbound
#     path also shells out to it; for inbound-only WebSocket transport
#     the CLI is only needed at send time.
#   - Register Hermes as a workspace member. That's a buzz-admin step on
#     the relay container, owned by servers/grr-buzz.md Phase 2.
#   - Create the demo room, post an @-mention, verify Hermes replies.
#     HITL via the buzz CLI (no desktop client needed — see Phase 3
#     "Drive the round-trip text demo" below).
set -euo pipefail

HOST="${HOST:-grr}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"

copy_local_to_remote() {
  scp -q "$1" "$HOST:$2"
}

remote_bash() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" bash -s -- "$@"
}

echo "target=$HOST"

remote_bash <<'EOS'
set -euo pipefail
HERMES="$HOME/.local/bin/hermes"
ENV="$HOME/.hermes/.env"
CFG="$HOME/.hermes/config.yaml"

# Install the real buzz CLI from the official desktop AppImage.
#
# The Hermes buzz plugin's connect() hard-fails if BUZZ_CLI_PATH (or
# the 'buzz' binary on PATH) is missing. The real CLI is a Rust crate (block/buzz
# crates/buzz-cli); it's NOT published as a standalone binary — only the
# desktop AppImage bundles it at usr/bin/buzz. We download the AppImage
# for v0.5.2 (latest at writing), extract the squashfs, and install
# usr/bin/buzz to ~/.local/bin/buzz.
#
# For the v0 inbound demo a Python shim at host-plane/buzz-shim/buzz
# would suffice, but the full round-trip (#49) needs the real CLI for
# outbound Hermes->Buzz sends. We install the real one from the start
# to avoid a second toolchain swap later.
#
# We install to ~/.local/bin/buzz (writable by the user, not requiring
# sudo) and set BUZZ_CLI_PATH explicitly in ~/.hermes/.env below —
# ~/.local/bin is not on the default PATH for systemd --user services.
APPIMAGE_URL='https://github.com/block/buzz/releases/download/v0.5.2/Buzz_0.5.2_amd64.AppImage'
appimage="/tmp/buzz-desktop.AppImage"
workdir="/tmp/buzz-appimage-extract"
if [[ ! -x "$HOME/.local/bin/buzz" ]]; then
  mkdir -p "$workdir"
  curl -fsSL -o "$appimage" "$APPIMAGE_URL"
  chmod +x "$appimage"
  # Extract without running; the AppImage ships a self-extractor.
  (cd "$workdir" && "$appimage" --appimage-extract >/dev/null)
  install -m 0755 "$workdir/squashfs-root/usr/bin/buzz" "$HOME/.local/bin/buzz"
  rm -rf "$appimage" "$workdir"
fi
# Always drop the shim if it survived a previous run — the real CLI supersedes it.
# (Line 83 in the remote script; the backtick-free version is below.)
if [[ -x "$HOME/.local/bin/buzz" ]]; then
  echo "  CLI present (no install needed)"
else
  echo "FATAL: $HOME/.local/bin/buzz missing — install failed?" >&2
  exit 1
fi

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
# 1. Determine the home channel UUID. If BUZZ_HOME_CHANNEL is already set
#    in ~/.hermes/.env (operator has populated it after creating the demo
#    room), preserve it. Otherwise generate a placeholder UUID the operator
#    must replace before the plugin will see any traffic.
# ---------------------------------------------------------------------------
home_uuid="$(grep -E '^BUZZ_HOME_CHANNEL=' "$ENV" 2>/dev/null | head -n1 | cut -d= -f2-)"
if [[ -z "$home_uuid" || "$home_uuid" == "REPLACE_ME" ]]; then
  home_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  echo "  placeholder room UUID: $home_uuid (operator MUST overwrite after creating the demo room)"
else
  echo "  reusing existing BUZZ_HOME_CHANNEL: $home_uuid"
fi
channels_value="$(grep -E '^BUZZ_CHANNELS=' "$ENV" 2>/dev/null | head -n1 | cut -d= -f2-)"
if [[ -z "$channels_value" || "$channels_value" == "REPLACE_ME" ]]; then
  channels_value="$home_uuid"
fi

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
# Loopback-only v0. BUZZ_HOME_CHANNEL + BUZZ_CHANNELS are UUIDs the operator
# sets (after creating the demo room with 'buzz channels create'). BUZZ_CLI_PATH
# points at the real buzz CLI installed by this script from the desktop
# AppImage. BUZZ_ALLOWED_USERS is comma-separated (the plugin parses with
# split(','); brackets or JSON arrays are NOT valid).
BUZZ_RELAY_URL=ws://127.0.0.1:3000
BUZZ_TRANSPORT=websocket
BUZZ_HOME_CHANNEL=$home_uuid
BUZZ_CHANNELS=$channels_value
BUZZ_ALLOWED_USERS=__HERMES_PUBHEX_PLACEHOLDER__
BUZZ_CLI_PATH=$HOME/.local/bin/buzz
EOC
chmod 0600 "$ENV"

# ---------------------------------------------------------------------------
# 3. Compute Hermes's pubhex from the chezmoi mirror at ~/.hermes/nostr.npub,
#    and pre-compute the allow-list BEFORE writing anything to $ENV
#    (idempotent re-runs need to preserve operator-added pubkeys).
# ---------------------------------------------------------------------------
hermes_pubhex="$(python3 - <<'PY'
import os
npub_file = os.path.expanduser("~/.hermes/nostr.npub")
if os.path.exists(npub_file):
    with open(npub_file) as f:
        for line in f:
            line = line.strip()
            if line.startswith("npub1"):
                CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
                s = line[5:]
                data = [CHARSET.index(c) for c in s if c in CHARSET]
                acc, bits, out = 0, 0, bytearray()
                for v in data[:-6]:
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

# Read the existing allow-list BEFORE we drop BUZZ_* lines from $ENV.
existing_allow="$(grep -E '^BUZZ_ALLOWED_USERS=' "$ENV" 2>/dev/null | head -n1 | cut -d= -f2-)"
# Tolerate accidental JSON/bracket syntax from manual edits.
existing_allow="$(echo "$existing_allow" | tr -d '[]"'\''')"
IFS=',' read -r -a allow_parts <<< "$existing_allow"
seen="$hermes_pubhex"
new_allow="$hermes_pubhex"
for p in "${allow_parts[@]}"; do
  p="$(echo "$p" | xargs)"
  [[ -z "$p" ]] && continue
  # 64-char hex only (skip empty / placeholder markers)
  if [[ "$p" =~ ^[0-9a-fA-F]{64}$ ]] && [[ ",$seen," != *,$p,* ]]; then
    new_allow="$new_allow,$p"
    seen="$seen,$p"
  fi
done

# Rewrite the placeholder line in $tmp with the computed allow-list,
# then move the temp into place. (sed must run on $tmp BEFORE the mv,
# since mv leaves the temp path dangling.)
sed -i "s|^BUZZ_ALLOWED_USERS=__HERMES_PUBHEX_PLACEHOLDER__\$|BUZZ_ALLOWED_USERS=$new_allow|" "$tmp"
mv "$tmp" "$ENV"
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