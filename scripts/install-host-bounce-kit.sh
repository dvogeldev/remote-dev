#!/usr/bin/env bash
# Install the host-plane bounce kit on grr (ADR-0008 / issue #25).
# From the laptop:  HOST=grr ./scripts/install-host-bounce-kit.sh
# On the VPS clone: ./scripts/install-host-bounce-kit.sh
# Does not chsh. Does not brew-install herdr. Does not chezmoi apply.
set -euo pipefail

HOST="${HOST:-}"
BREW_PREFIX="/home/linuxbrew/.linuxbrew"

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
BREWFILE="${ROOT}/host-plane/Brewfile"
DROPIN_SRC="${ROOT}/host-plane/herdr.service.d/linuxbrew.conf"
MISE_TOML="${ROOT}/host-plane/mise.toml"

if [[ ! -f "$BREWFILE" ]]; then
  echo "missing Brewfile: $BREWFILE" >&2
  exit 1
fi
if [[ ! -f "$DROPIN_SRC" ]]; then
  echo "missing herdr drop-in: $DROPIN_SRC" >&2
  exit 1
fi

remote_bash() {
  if [[ -n "$HOST" ]]; then
    ssh -o BatchMode=yes "$HOST" bash -s
  else
    bash -s
  fi
}

ensure_host_deps() {
  remote_bash <<'EOS'
set -euo pipefail
run_root() {
  if sudo -n true 2>/dev/null; then
    sudo -n "$@"
    return
  fi
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    docker run --rm --privileged --pid=host ubuntu:24.04 nsenter -t 1 -m -u -i -n "$@"
    return
  fi
  echo "Need sudo -n or rootful docker for: $*" >&2
  exit 1
}
if ! command -v file >/dev/null; then
  run_root apt-get update -y
  run_root apt-get install -y --no-install-recommends file
fi
if [[ ! -d /home/linuxbrew/.linuxbrew ]]; then
  run_root mkdir -p /home/linuxbrew/.linuxbrew
  run_root chown -R "$(id -u)":"$(id -g)" /home/linuxbrew
fi
if [[ ! -O /home/linuxbrew/.linuxbrew ]]; then
  echo "/home/linuxbrew/.linuxbrew is not owned by $(id -un)" >&2
  exit 1
fi
echo "prefix ok"
EOS
}

install_brew() {
  remote_bash <<'EOS'
set -euo pipefail
prefix=/home/linuxbrew/.linuxbrew
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
if [[ -x $prefix/bin/brew ]]; then
  echo "brew already present"
  exit 0
fi
mkdir -p "$prefix/bin"
if [[ ! -d $prefix/Homebrew/.git ]]; then
  git clone --depth 1 https://github.com/Homebrew/brew "$prefix/Homebrew"
fi
ln -sfn ../Homebrew/bin/brew "$prefix/bin/brew"
eval "$("$prefix/bin/brew" shellenv bash)"
brew update --force --quiet
echo "brew $($prefix/bin/brew --version | head -n1)"
EOS
}

bundle_kit() {
  if [[ -n "$HOST" ]]; then
    scp -q "$BREWFILE" "$HOST:/tmp/remote-dev-Brewfile"
    ssh -o BatchMode=yes "$HOST" bash -s <<'EOS'
set -euo pipefail
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
brew bundle --file /tmp/remote-dev-Brewfile
rm -f /tmp/remote-dev-Brewfile
EOS
  else
    export HOMEBREW_NO_ANALYTICS=1
    export HOMEBREW_NO_ENV_HINTS=1
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
    brew bundle --file "$BREWFILE"
  fi
}

install_mise_tools() {
  if [[ ! -f "$MISE_TOML" ]]; then
    echo "missing $MISE_TOML" >&2
    exit 1
  fi
  if [[ -n "$HOST" ]]; then
    ssh -o BatchMode=yes "$HOST" mkdir -p ~/.config/mise
    scp -q "$MISE_TOML" "$HOST:.config/mise/config.toml"
    ssh -o BatchMode=yes "$HOST" bash -s <<'EOS'
set -euo pipefail
export HOMEBREW_NO_ANALYTICS=1
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
mise install
mise reshim
# Hermes is bash; shims so non-interactive node/python work.
touch "$HOME/.bashrc"
if ! grep -q 'mise activate bash --shims' "$HOME/.bashrc"; then
  {
    echo ''
    echo '# host-plane mise (remote-dev host-plane/mise.toml)'
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"'
    echo 'command -v mise >/dev/null && eval "$(mise activate bash --shims)"'
  } >> "$HOME/.bashrc"
fi
EOS
  else
    mkdir -p "${HOME}/.config/mise"
    cp "$MISE_TOML" "${HOME}/.config/mise/config.toml"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
    mise install
    mise reshim
  fi
}

patch_herdr_path() {
  if [[ -n "$HOST" ]]; then
    ssh -o BatchMode=yes "$HOST" mkdir -p ~/.config/systemd/user/herdr.service.d
    scp -q "$DROPIN_SRC" "$HOST:.config/systemd/user/herdr.service.d/linuxbrew.conf"
    ssh -o BatchMode=yes "$HOST" bash -s <<'EOS'
set -euo pipefail
systemctl --user daemon-reload
systemctl --user restart herdr.service
systemctl --user --quiet is-active herdr.service
EOS
  else
    mkdir -p "${HOME}/.config/systemd/user/herdr.service.d"
    cp "$DROPIN_SRC" "${HOME}/.config/systemd/user/herdr.service.d/linuxbrew.conf"
    systemctl --user daemon-reload
    systemctl --user restart herdr.service
    systemctl --user --quiet is-active herdr.service
  fi
}

verify() {
  remote_bash <<'EOS'
set -euo pipefail
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
echo "brew=$(command -v brew)"
brew list --formula
echo "--- herdr PATH ---"
systemctl --user show herdr.service -p Environment
echo "--- kit ---"
fail=0
for c in bat eza fd fish fzf lazygit mise nvim rg yazi zoxide; do
  p="$(command -v "$c" || true)"
  case "$p" in
    /home/linuxbrew/.linuxbrew/*) echo "ok $c $p" ;;
    *) echo "MISSING $c (${p:-not on PATH})"; fail=1 ;;
  esac
done
echo "--- mise ---"
eval "$(mise activate bash --shims)"
mise ls
node -v
python -V
echo "--- login ---"
getent passwd "$USER" | awk -F: '{print $7}'
systemctl --user is-active herdr.service
exit "$fail"
EOS
}

echo "target=${HOST:-local} root=$ROOT"
ensure_host_deps
install_brew
bundle_kit
install_mise_tools
patch_herdr_path
verify
echo "bounce kit + mise node/python installed."
