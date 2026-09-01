#!/usr/bin/env bash
# Install hermes-dashboard as a systemd --user service on grr.
# Per #30: loopback bind (no in-box auth gate), Restart=on-failure,
# lingering on, /api/status is the health probe. Does NOT configure
# the Cloudflare Tunnel (#35 is that ticket). Does NOT install
# Hermes itself — run install.sh first.
set -euo pipefail

HOST="${HOST:-}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
UNIT_SRC="${ROOT}/host-plane/hermes-dashboard.service"
REMOTE_UNIT=/tmp/hermes-dashboard.service

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

install_web_extras() {
  remote_bash <<'EOS'
set -euo pipefail
if [[ ! -d "$HOME/.hermes/hermes-agent" ]]; then
  echo "WARN: ~/.hermes/hermes-agent missing; run install.sh before this script." >&2
  exit 1
fi
(cd "$HOME/.hermes/hermes-agent" && uv pip install -e ".[web,pty]")
EOS
}

install_unit() {
  remote_bash <<'EOS'
set -euo pipefail
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 /tmp/hermes-dashboard.service "$HOME/.config/systemd/user/hermes-dashboard.service"
EOS
}

enable_linger() {
  remote_bash <<'EOS'
set -euo pipefail
if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
  echo "linger already on for $USER"
  exit 0
fi
if sudo -n true 2>/dev/null; then
  sudo -n loginctl enable-linger "$USER"
else
  echo "WARN: cannot enable linger non-interactively; run 'sudo loginctl enable-linger $USER' manually." >&2
  exit 1
fi
EOS
}

start_service() {
  remote_bash <<'EOS'
set -euo pipefail
systemctl --user daemon-reload
systemctl --user enable --now hermes-dashboard.service
EOS
}

verify() {
  remote_bash <<'EOS'
set -euo pipefail
systemctl --user --quiet is-active hermes-dashboard.service
sleep 1
if ! curl -fsS http://127.0.0.1:9119/api/status >/dev/null; then
  echo "WARN: /api/status not reachable; tail 'journalctl --user -u hermes-dashboard.service -n 50'" >&2
  exit 1
fi
echo "ok: hermes-dashboard.service active, /api/status 200"
EOS
}

echo "target=${HOST:-local} unit=$UNIT_SRC"
copy_unit
install_web_extras
install_unit
enable_linger
start_service
verify