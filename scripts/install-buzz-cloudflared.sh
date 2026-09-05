#!/usr/bin/env bash
# Lay down the cloudflared-buzz.service unit on grr (#53).
#
# The cloudflared binary itself is installed by scripts/install-cloudflared.sh
# (which also installs the hermes-gui tunnel unit). This script handles only
# the Buzz tunnel unit — kept separate so install-buzz.sh can call it without
# re-installing the dashboard's tunnel.
#
# AFK parts only. The CF-dashboard steps (tunnel login, create, Access app,
# policy) are in servers/buzz-dvogeldev-access.md.
#
# Idempotent: re-running on a populated ~/.cloudflared/buzz-config.yml is a
# no-op; running with a placeholder config (still <TUNNEL-UUID>) is also a
# no-op (the unit would fail-loop and pollute journalctl).
set -euo pipefail

HOST="${HOST:-}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
UNIT_SRC="${ROOT}/host-plane/cloudflared-buzz.service"
REMOTE_UNIT=/tmp/cloudflared-buzz.service

if [[ ! -f "$UNIT_SRC" ]]; then
  echo "missing unit: $UNIT_SRC" >&2
  exit 1
fi

remote_bash() {
  if [[ -n "$HOST" ]]; then
    ssh -o BatchMode=yes "$HOST" bash -s
  else
    bash -s
  fi
}

copy_unit() {
  if [[ -n "$HOST" ]]; then
    scp -q "$UNIT_SRC" "$HOST:$REMOTE_UNIT"
  else
    cp "$UNIT_SRC" "$REMOTE_UNIT"
  fi
}

install_unit() {
  remote_bash <<'EOS'
set -euo pipefail
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 /tmp/cloudflared-buzz.service "$HOME/.config/systemd/user/cloudflared-buzz.service"
mkdir -p "$HOME/.cloudflared"
systemctl --user daemon-reload
# enable --now only if a valid buzz-config.yml already exists; otherwise
# the unit will fail-loop and pollute journalctl.
if [[ -s "$HOME/.cloudflared/buzz-config.yml" ]] && ! grep -q '<TUNNEL-UUID>' "$HOME/.cloudflared/buzz-config.yml"; then
  systemctl --user enable --now cloudflared-buzz.service
  echo "cloudflared-buzz.service started"
else
  echo "skip start: ~/.cloudflared/buzz-config.yml is missing or still a template."
  echo "finish servers/buzz-dvogeldev-access.md then re-run with --start"
fi
EOS
}

maybe_start() {
  if [[ "${1:-}" == "--start" ]]; then
    remote_bash <<'EOS'
set -euo pipefail
systemctl --user enable --now cloudflared-buzz.service
EOS
  fi
}

# Idempotent: insert /pair* → 127.0.0.1:5000 ahead of the catch-all if missing.
ensure_pair_ingress() {
  remote_bash <<'EOS'
set -euo pipefail
cfg="$HOME/.cloudflared/buzz-config.yml"
[[ -s "$cfg" ]] || { echo "skip pair ingress: no $cfg"; exit 0; }
if grep -qE 'path:[[:space:]]*/pair' "$cfg"; then
  echo "pair ingress already present in $cfg"
  exit 0
fi
python3 - "$cfg" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
needle = "ingress:\n"
block = """ingress:
  - hostname: buzz.dvogeldev.com
    path: /pair.*
    service: http://127.0.0.1:5000
"""
if needle not in text:
    sys.exit("FATAL: no ingress: key in " + str(p))
p.write_text(text.replace(needle, block, 1))
print("inserted /pair* ingress ahead of catch-all")
PY
EOS
}

echo "target=${HOST:-local} unit=$UNIT_SRC"
copy_unit
install_unit
ensure_pair_ingress
maybe_start "${1:-}"
