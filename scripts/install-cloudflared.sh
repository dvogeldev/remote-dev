#!/usr/bin/env bash
# Install cloudflared on grr and lay down the user-unit.
# Per #35: AFK parts only. The CF-dashboard steps (tunnel login,
# create, Access app, policy) are in servers/hermes-dvogeldev-access.md.
set -euo pipefail

HOST="${HOST:-}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
UNIT_SRC="${ROOT}/host-plane/cloudflared.service"
REMOTE_UNIT=/tmp/cloudflared.service

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

install_binary() {
  remote_bash <<'EOS'
set -euo pipefail
bin="$HOME/.local/bin/cloudflared"
mkdir -p "$(dirname "$bin")"
if [[ -x "$bin" ]]; then
  echo "cloudflared already present: $("$bin" --version | head -n1)"
  exit 0
fi
url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
curl -fsSL -o "$bin.tmp" "$url"
install -m 0755 "$bin.tmp" "$bin"
rm -f "$bin.tmp"
echo "installed: $("$bin" --version | head -n1)"
EOS
}

install_unit() {
  remote_bash <<'EOS'
set -euo pipefail
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 /tmp/cloudflared.service "$HOME/.config/systemd/user/cloudflared.service"
mkdir -p "$HOME/.cloudflared"
EOS
}

reload() {
  remote_bash <<'EOS'
set -euo pipefail
systemctl --user daemon-reload
# enable --now only if a valid config.yml already exists; otherwise
# the unit will fail-loop and pollute journalctl.
if [[ -s "$HOME/.cloudflared/config.yml" ]] && ! grep -q '<TUNNEL-UUID>' "$HOME/.cloudflared/config.yml"; then
  systemctl --user enable --now cloudflared.service
  echo "cloudflared.service started"
else
  echo "skip start: ~/.cloudflared/config.yml is missing or still a template."
  echo "finish servers/hermes-dvogeldev-access.md then re-run with --start"
fi
EOS
}

maybe_start() {
  if [[ "${1:-}" == "--start" ]]; then
    remote_bash <<'EOS'
set -euo pipefail
systemctl --user enable --now cloudflared.service
EOS
  fi
}

echo "target=${HOST:-local} unit=$UNIT_SRC"
copy_unit
install_binary
install_unit
reload
maybe_start "${1:-}"